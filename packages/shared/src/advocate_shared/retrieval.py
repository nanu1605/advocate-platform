"""Hybrid retrieval over an organisation's case files (spec §12.4): vector top 40 and full-text top 40 → reciprocal-rank
fusion → rerank → top 8, always within one organisation and, when asked about one case, within that case. Search
inside scans uses it, and Ask (P2 task 6) will.

Run it on the user's connection: row-level security then limits it too. A document's chunks are its organisation's; a
court order's are shared, so they are reached through the organisation's own `orders` rows. Deleted documents and
orders, and files still waiting for their scan, are skipped. The nearest chunks are found by exact distance over the
organisation's own chunks, so the filters never starve the result as they can after an index scan (ADR 0019).
Without an embedder the full text alone answers.

Full text puts the chunks with every query word first, and matches and ranks the rest by the words other than COMMON
function words. A chunk only the vector branch found is kept only when the reranker scores it MIN_SCORE or more, and
dropped without the reranker, so a page that neither holds a query word nor reranks well is not a hit."""

import asyncio
from dataclasses import dataclass
from uuid import UUID

import httpx
import structlog
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_shared import embedder

log = structlog.get_logger()

# ponytail: exact distance, as an organisation has thousands of chunks; at hundreds of thousands, an HNSW scan per
# branch with hnsw.iterative_scan
CANDIDATES = 40
TOP = 8
RRF_K = 60
# For the embedder and the reranker together, then the search answers without them: under the app's 20 s receive timeout
WAIT_S = 10
# ponytail: a guess, to tune on real queries; bge-reranker-v2-m3's sigmoid scored a bail order 0.46 (Hindi) and 0.59
# (English) for "bail granted to the accused", and an unrelated reply 0.0
MIN_SCORE = 0.2

# The chunks the organisation can search, with what the app needs to open them; :matter narrows to one case.
VISIBLE = """
select c.id as chunk_id, c.page_no, c.paras, c.text, d.id as document_id, null::uuid as order_id, d.matter_id,
       d.title, {score} as score
from public.document_chunks c join public.documents d on d.id = c.document_id
where c.org_id = :org and d.org_id = :org and d.deleted_at is null and d.upload_status = 'ready'
  and (cast(:matter as uuid) is null or d.matter_id = cast(:matter as uuid)) and {match}
union all
select c.id, c.page_no, c.paras, c.text, null, o.id, o.matter_id, o.title, {score}
from public.document_chunks c join public.orders o on o.court_order_id = c.court_order_id
where o.org_id = :org and o.deleted_at is null
  and (cast(:matter as uuid) is null or o.matter_id = cast(:matter as uuid)) and {match}
order by score {direction} limit :n
"""
QUERY = "plainto_tsquery('simple', public.search_text(:q))"
# Any of the words, COMMON's left out (:any). Chunks with all the words come first, then by cover density.
# Normalisation 32 (rank / (rank + 1)) keeps that below 1: it counts every hit of a word, so a chunk full of one would
# otherwise outrank one with all of them.
ANY_WORD = "replace(plainto_tsquery('simple', public.search_text(:any))::text, '&', '|')::tsquery"
# On nearly every page ('simple' keeps them), so they would match and rank pages that hold none of the other words.
COMMON = frozenset("का के की को में पर से ने और है तथा एवं the of to a an and in on for by is with at as".split())
FULL_TEXT = VISIBLE.format(
    score=f"(c.tsv @@ {QUERY})::int + ts_rank_cd(c.tsv, {ANY_WORD}, 32)", match=f"c.tsv @@ {ANY_WORD}", direction="desc"
)
NEAREST = VISIBLE.format(
    score="c.embedding <=> cast(:v as extensions.vector)", match="c.embedding is not null", direction="asc"
)


@dataclass(frozen=True)
class Hit:
    chunk_id: UUID
    page_no: int
    paras: list[str]
    text: str
    document_id: UUID | None  # an uploaded document's chunk
    order_id: UUID | None  # or a court order's, through the organisation's orders row
    matter_id: UUID | None
    title: str


async def _ranked(conn: AsyncConnection, sql: str, **params: object) -> list[Hit]:
    rows = (await conn.execute(text(sql), {"n": CANDIDATES, **params})).mappings()
    return [Hit(**{k: v for k, v in row.items() if k != "score"}) for row in rows]


async def search(conn: AsyncConnection, org_id: UUID, query: str, *, matter_id: UUID | None = None) -> list[Hit]:
    """The TOP chunks for `query` in the organisation's files, most relevant first."""
    deadline = asyncio.get_running_loop().time() + WAIT_S
    any_word = " ".join(w for w in query.split() if fold(w) not in COMMON) or query  # as typed if all are common
    params = {"org": org_id, "matter": matter_id, "q": query, "any": any_word}
    lists = [await _ranked(conn, FULL_TEXT, **params)]
    keep = {h.chunk_id for h in lists[0]}  # the full text's hits, and below the vector branch's that rerank well
    client = embedder.configured()
    if client is not None:
        try:
            async with asyncio.timeout_at(deadline):
                [v] = await client.embed([query])
            lists.append(await _ranked(conn, NEAREST, v=embedder.vector(v), **params))
        except (httpx.HTTPError, TimeoutError) as e:
            log.warning("embedder_unavailable", error=type(e).__name__)
            client = None
    fused: dict[UUID, float] = {}
    hits: dict[UUID, Hit] = {}
    for ranked in lists:
        for rank, hit in enumerate(dict.fromkeys(h.chunk_id for h in ranked)):  # a court order linked twice: once
            fused[hit] = fused.get(hit, 0) + 1 / (RRF_K + rank + 1)
        hits |= {h.chunk_id: h for h in ranked}
    candidates = sorted(fused, key=fused.__getitem__, reverse=True)[:CANDIDATES]
    if client is not None and candidates:
        try:
            async with asyncio.timeout_at(deadline):
                scores = await client.rerank(query, [hits[c].text for c in candidates])
            keep |= {c for s, c in zip(scores, candidates, strict=True) if s >= MIN_SCORE}
            candidates = [c for _, c in sorted(zip(scores, candidates, strict=True), key=lambda p: -p[0])]
        except (httpx.HTTPError, TimeoutError) as e:
            log.warning("reranker_unavailable", error=type(e).__name__)
    return [hits[c] for c in candidates if c in keep][:TOP]


# The same folding as the database's public.search_text, so a snippet finds the word the search matched.
FOLD = str.maketrans(
    "\u0966\u0967\u0968\u0969\u096a\u096b\u096c\u096d\u096e\u096f"  # Devanagari 0-9
    "\u0958\u0959\u095a\u095b\u095c\u095d\u095e\u095f\u0929\u0931\u0934"  # precomposed nukta letters
    "\u0901",  # chandrabindu
    "0123456789\u0915\u0916\u0917\u091c\u0921\u0922\u092b\u092f\u0928\u0930\u0933\u0902",
    "\u093c\u0903\u200c\u200d",  # nukta, visarga, ZWNJ, ZWJ: dropped
)
SNIPPET = 160  # characters


def fold(s: str) -> str:
    return s.lower().translate(FOLD)


def snippet(text: str, query: str) -> str:
    """About SNIPPET characters of `text` around the first word of `query` in it (COMMON's skipped, as in the search),
    cut at spaces (or its start)."""
    folded = [(i, f) for i, c in enumerate(text) if (f := fold(c))]  # original index of each folded character
    flat = "".join(f for _, f in folded)
    words = fold(query).split()
    found = [at for w in [w for w in words if w not in COMMON] or words if (at := flat.find(w)) >= 0]
    centre = folded[min(found)][0] if found else 0
    start = max(0, centre - SNIPPET // 3)
    end = min(len(text), start + SNIPPET)
    if start > 0 and (space := text.find(" ", start, centre)) >= 0:
        start = space + 1
    if end < len(text) and (space := text.rfind(" ", centre, end)) > centre:
        end = space
    cut = " ".join(text[start:end].split())
    return ("\u2026" if start > 0 else "") + cut + ("\u2026" if end < len(text) else "")
