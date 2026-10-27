"""Order summaries and order intelligence (spec §4.4 F07, F13, §12.8, ADR 0023), for the workers' order pipeline and
on-demand jobs and the API's cached answers.

A court order's summary and intelligence are made once per language and shared through `public_summaries` (doc_kind
`court_order`, `order_intel`); a summary is copied to every organisation's `orders.summary_<language>`. An uploaded
order's summary is its organisation's (`ai_answers`, kind `upload_summary`). The model reads the order one page per
source, so a stored output carries `source_pages` ({"S1": 1, …}) for the app's page chips. One Redis lock per task,
source and language keeps two workers from paying for the same output. Intelligence becomes proposed tasks and
deadlines per organisation, which a member confirms or dismisses (nothing is added on its own, hard rule 2).

Connections: `Connect` opens a service-role transaction (workers: `db.engine().begin`, API: `service_db`); the model
is called between transactions, so none is held open while it thinks, and a failed run is still recorded."""

import hashlib
import json
from collections.abc import Callable, Iterable, Sequence
from contextlib import AbstractAsyncContextManager
from datetime import date, datetime, time
from typing import TYPE_CHECKING, Any, Literal
from uuid import uuid4

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_shared import ai
from advocate_shared.ist import IST
from legal_ai.contracts import Action, OrderIntel, OrderSummary
from legal_ai.llm import AIError
from legal_ai.prompts import Source, load_prompt

if TYPE_CHECKING:
    from redis.asyncio import Redis

type Connect = Callable[[], AbstractAsyncContextManager[AsyncConnection]]
type Kind = Literal["court_order", "document"]  # what is summarised: a court order, or an uploaded order
type Doc = Literal["court_order", "order_intel", "document"]  # what is stored: its summary, its intelligence
type Language = Literal["hi", "en"]
type Billing = Literal["automatic", "credits"]

# ponytail: a run slower than the lock (Bedrock's read timeout is 900 s an attempt) can overlap a second one, which
# pays again for the same output; lengthen it if real calls come near.
LOCK_TTL_S = 900
RELEASE = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end return 0"
TASKS: dict[Doc, str] = {"court_order": "order_summary", "document": "order_summary", "order_intel": "order_intel"}
COLUMN: dict[Kind, str] = {"court_order": "court_order_id", "document": "document_id"}

TEXT = {
    "court_order": "select text_status, exists (select 1 from public.document_chunks where court_order_id = o.id) "
    "as chunks from public.court_orders o where o.id = cast(:id as uuid)",
    "document": "select text_status, exists (select 1 from public.document_chunks where document_id = d.id) as chunks "
    "from public.documents d where d.id = cast(:id as uuid) and d.deleted_at is null and d.upload_status = 'ready'",
}
UPLOAD_SUMMARY = """
select answer from public.ai_answers
where document_id = cast(:d as uuid) and language = :l and kind = 'upload_summary' and deleted_at is null
"""
STORE_UPLOAD_SUMMARY = """
insert into public.ai_answers (org_id, run_id, matter_id, document_id, kind, language, answer, sources, created_by)
values (:o, :run, :m, :d, 'upload_summary', :l, cast(:a as jsonb), cast(:s as jsonb), :u)
on conflict (document_id, language) where kind = 'upload_summary' and deleted_at is null do nothing
"""
# Every organisation's row; an unchanged one is left alone, so devices don't re-sync it.
FAN_OUT = {
    lang: f"update public.orders set summary_{lang} = cast(:s as jsonb) where court_order_id = cast(:co as uuid) "  # noqa: S608
    f"and deleted_at is null and summary_{lang} is distinct from cast(:s as jsonb)"
    for lang in ("hi", "en")
}
ORDER_DATE = """
select coalesce(o.order_date, (
  select cast(s.summary->>'order_date' as date) from public.public_summaries s
  where s.doc_kind = 'court_order' and s.doc_ref = :co and s.summary->>'order_date' is not null
  order by s.updated_at desc limit 1))
from public.court_orders o where o.id = cast(:co as uuid)
"""
# A matter's task or deadline (not dismissed) with the same title, folded, and the same due date.
SAME = r"""
with t as (select regexp_replace(lower(btrim(cast(:t as text))), '\s+', ' ', 'g') as folded)
select exists (
  select 1 from public.tasks, t
  where matter_id = :m and deleted_at is null and status in ('proposed', 'open', 'done')
    and regexp_replace(lower(btrim(title)), '\s+', ' ', 'g') = t.folded
    and (due_at at time zone 'Asia/Kolkata')::date is not distinct from cast(:due as date)
) or exists (
  select 1 from public.deadlines, t
  where matter_id = :m and deleted_at is null and status in ('proposed', 'active', 'done')
    and regexp_replace(lower(btrim(basis->>'title')), '\s+', ' ', 'g') = t.folded and due_date = cast(:due as date)
)
"""
# Whether an organisation's order was read for actions already: any task or deadline from it, whatever its status,
# deleted or not.
FROM_ORDER = """
select exists (select 1 from public.tasks where org_id = :o and source = 'order' and source_ref = :ref)
    or exists (select 1 from public.deadlines where org_id = :o and source_order_id = cast(:ref as uuid))
"""
PROPOSE_TASK = """
insert into public.tasks (org_id, matter_id, title, due_at, status, source, source_ref, dedupe_key)
values (:o, :m, :t, :at, 'proposed', 'order', :ref, :key)
on conflict (org_id, dedupe_key) do nothing
"""
PROPOSE_DEADLINE = """
insert into public.deadlines (org_id, matter_id, kind, due_date, basis, source_order_id, status, dedupe_key)
values (:o, :m, 'compliance', :due, cast(:basis as jsonb), :ref, 'proposed', :key)
on conflict (org_id, dedupe_key) do nothing
"""


class NoText(Exception):
    """The source has no text to read: none yet, unreadable, or blank. Check `text_state` first."""


class CreditsExhausted(Exception):
    """The organisation has fewer credits left this month than the on-demand run's price (nothing was charged)."""


type TextState = Literal["ready", "pending", "unreadable"]


async def text_state(conn: AsyncConnection, kind: Kind, source_id: str) -> TextState | None:
    """Whether a court order's or a ready upload's text can be summarised: ready (read, with chunks), pending (not
    read yet, or waiting for OCR), unreadable (failed, or blank). None when it is gone (or an upload isn't ready)."""
    row = (await conn.execute(text(TEXT[kind]), {"id": source_id})).mappings().one_or_none()
    if row is None:
        return None
    if row["text_status"] in ("none", "ocr_pending"):
        return "pending"
    return "ready" if row["text_status"] != "failed" and row["chunks"] else "unreadable"


def join_pages(chunks: Iterable[tuple[int, str]]) -> list[Source]:
    """One source per page from its chunks, given as (page_no, text) in (page_no, chunk_no) order. A chunk is an exact
    slice of its page that repeats the end of the one before (doctext.chunks), so each is laid onto the page so far
    by their longest overlap. A blank page has no chunks: the others keep their real page numbers.
    ponytail: a page that repeats itself for longer than the overlap could lose a repeat; store page text (F15) if
    that shows up."""
    pages: dict[int, str] = {}
    for page_no, chunk in chunks:
        before = pages.get(page_no)
        pages[page_no] = chunk if before is None else before + chunk[_overlap(before, chunk) :]
    return [Source("order", page, page=n) for n, page in pages.items()]


def _overlap(a: str, b: str) -> int:
    """The length of the longest end of `a` that `b` starts with."""
    i = max(0, len(a) - len(b))
    while (i := a.find(b[:1], i)) >= 0:
        if b.startswith(a[i:]):
            return len(a) - i
        i += 1
    return 0


async def page_sources(conn: AsyncConnection, kind: Kind, source_id: str) -> list[Source]:
    """The order's pages as sources S1…Sn (ADR 0023)."""
    result = await conn.execute(
        text(
            f"select page_no, text from public.document_chunks where {COLUMN[kind]} = cast(:id as uuid) "  # noqa: S608
            "order by page_no, chunk_no"
        ),
        {"id": source_id},
    )
    return join_pages((row.page_no, row.text) for row in result)


def source_pages(sources: Sequence[Source]) -> dict[str, int]:
    """{"S1": 1, "S2": 3, …}: the page each source id stands for."""
    return {f"S{i}": s.page for i, s in enumerate(sources, 1) if s.page is not None}


async def cached(conn: AsyncConnection, doc: Doc, source_id: str, language: str) -> dict[str, Any] | None:
    """What is stored for `doc`: a court order's summary or intelligence made with the current prompt version (a new
    version regenerates it), or an upload's live summary."""
    if doc != "document":
        return await ai.cached_summary(conn, doc, source_id, language, load_prompt(TASKS[doc]).version)
    answer = (await conn.execute(text(UPLOAD_SUMMARY), {"d": source_id, "l": language})).scalar_one_or_none()
    return json.loads(answer) if isinstance(answer, str) else answer


async def fan_out(conn: AsyncConnection, court_order_id: str, language: str, summary: dict[str, Any]) -> int:
    """Copy a court order's summary to every organisation's live orders row for it (they sync to devices). Returns
    the rows changed."""
    result = await conn.execute(
        text(FAN_OUT[language]), {"co": court_order_id, "s": json.dumps(summary, ensure_ascii=False)}
    )
    return result.rowcount  # type: ignore[attr-defined]


async def order_date(conn: AsyncConnection, court_order_id: str) -> date | None:
    """The order's date: the court's record of it, else what a stored summary read off the order."""
    return (await conn.execute(text(ORDER_DATE), {"co": court_order_id})).scalar_one_or_none()


async def summarise(
    connect: Connect,
    r: Redis,
    kind: Kind,
    source_id: str,
    language: Language,
    *,
    org_id: str,
    user_id: str | None = None,
    matter_id: str | None = None,
    billing: Billing,
    credits: int = 0,
) -> dict[str, Any] | None:
    """The `order_summary` of a court order (shared, then copied to every organisation's orders row) or of an upload
    (`ai_answers`, created_by `user_id`): `OrderSummary` fields plus `source_pages`. A stored one is returned free;
    otherwise it is made, its run billed to `org_id` (`billing` and `credits` as in `ai.record_run`; credits only for
    output) and stored. None while another run holds it. Raises AIError (its run recorded), NoText and
    CreditsExhausted (checked again here, as requests accepted together may have spent them since)."""
    return await _make(
        connect, r, kind, source_id, language, {},
        bill={"org_id": org_id, "user_id": user_id, "matter_id": matter_id, "billing": billing, "credits": credits},
    )  # fmt: skip


async def intel(
    connect: Connect,
    r: Redis,
    court_order_id: str,
    language: Language,
    order_date: date,
    *,
    org_id: str,
    user_id: str | None = None,
    matter_id: str | None = None,
    billing: Billing,
    credits: int = 0,
) -> dict[str, Any] | None:
    """The court order's `order_intel` in `language` (action titles are in it), shared like its summary:
    {"actions": [Action…], "order_date": "YYYY-MM-DD", "source_pages": {…}}. Otherwise as `summarise`."""
    return await _make(
        connect, r, "order_intel", court_order_id, language, {"order_date": order_date.isoformat()},
        bill={"org_id": org_id, "user_id": user_id, "matter_id": matter_id, "billing": billing, "credits": credits},
    )  # fmt: skip


async def _make(
    connect: Connect, r: Redis, doc: Doc, source_id: str, language: Language, params: dict[str, str], bill: dict
) -> dict[str, Any] | None:
    task = TASKS[doc]
    lock, token = f"ai:{task}:{source_id}:{language}", uuid4().hex
    if not await r.set(lock, token, nx=True, ex=LOCK_TTL_S):
        return None
    try:
        async with connect() as c:
            if (hit := await cached(c, doc, source_id, language)) is not None:
                if doc == "court_order":
                    await fan_out(c, source_id, language, hit)
                return hit
            sources = await page_sources(c, "document" if doc == "document" else "court_order", source_id)
            if bill["billing"] == "credits" and await ai.credits_left(c, bill["org_id"]) < bill["credits"]:
                raise CreditsExhausted(bill["org_id"])
        if not sources:
            raise NoText(source_id)
        if bill["billing"] == "credits" and bill["credits"] <= 0:
            raise ValueError("an on-demand run is charged at least one credit")  # before the model is paid
        output = OrderIntel if doc == "order_intel" else OrderSummary
        try:
            result = await ai.configured_llm().structured(
                task, output, language=language, params=params, sources=sources
            )
        except AIError as e:
            async with connect() as c:
                await ai.record_run(c, e.run, **bill)
            raise
        pages = source_pages(sources)
        made = result.output.model_dump(mode="json") | params | {"source_pages": pages}
        async with connect() as c:
            run_id = await ai.record_run(c, result.run, **bill)
            if doc == "document":
                await c.execute(
                    text(STORE_UPLOAD_SUMMARY),
                    {
                        "o": bill["org_id"],
                        "run": run_id,
                        "m": bill["matter_id"],
                        "d": source_id,
                        "l": language,
                        "a": json.dumps(made, ensure_ascii=False),
                        "s": json.dumps([{"id": k, "page": p} for k, p in pages.items()]),
                        "u": bill["user_id"],
                    },
                )
            else:
                await ai.store_summary(c, doc, source_id, language, made, result.run)
            if doc == "court_order":
                await fan_out(c, source_id, language, made)
        return made
    finally:
        await r.register_script(RELEASE)(keys=[lock], args=[token])


async def proposed_before(conn: AsyncConnection, org_id: str, order_id: str) -> bool:
    """Whether the organisation's order was read for actions already: it has a task or deadline from it, proposed,
    confirmed, dismissed or deleted. One reading per order per organisation, whatever the language."""
    return (await conn.execute(text(FROM_ORDER), {"o": org_id, "ref": order_id})).scalar_one()


def dedupe_key(court_order_id: str, action: Action, due: date | None) -> str:
    """order:{court order}:{hash of kind, folded title and due date}: one proposal per direction per organisation,
    however often the order is read (tasks and deadlines are unique on (org_id, dedupe_key), §9.3)."""
    folded = " ".join(action.title.lower().split())
    digest = hashlib.sha1(f"{action.kind}|{folded}|{due or ''}".encode(), usedforsecurity=False).hexdigest()
    return f"order:{court_order_id}:{digest[:12]}"


async def propose(
    conn: AsyncConnection, org_id: str, matter_id: str, order_id: str, court_order_id: str, intel: dict[str, Any]
) -> int:
    """An organisation's proposed tasks and deadlines from a court order's intelligence (§4.4 F13): a deadline with a
    due date counted from the order date, marked verify (`deadlines.basis`), else a task (due at IST midnight when
    the order gives a time). Skips one already proposed, and one the case already has as a task or deadline with the
    same title and due date. Adds nothing once the organisation has any row from this order (`proposed_before`), so
    intelligence in another language or from another prompt version never proposes the same direction again.
    `order_id` is the organisation's orders row. Returns the rows added ("N actions found")."""
    if await proposed_before(conn, org_id, order_id):
        return 0
    added = 0
    made_on = date.fromisoformat(intel["order_date"])
    pages = intel.get("source_pages", {})
    for action in (Action.model_validate(a) for a in intel["actions"]):
        due = action.due.resolve(made_on) if action.due else None
        title = action.title.strip()
        if (await conn.execute(text(SAME), {"m": matter_id, "t": title, "due": due})).scalar_one():
            continue
        row = {"o": org_id, "m": matter_id, "t": title, "ref": order_id, "key": dedupe_key(court_order_id, action, due)}
        if action.kind == "deadline" and action.due and due:
            basis = {
                "title": title,
                "due": action.due.model_dump(mode="json"),
                "order_date": intel["order_date"],
                "pages": sorted({pages[s] for s in action.sources if s in pages}),
                "verify": True,
            }
            result = await conn.execute(text(PROPOSE_DEADLINE), row | {"due": due, "basis": json.dumps(basis)})
        else:
            at = datetime.combine(due, time(), IST) if due else None
            result = await conn.execute(text(PROPOSE_TASK), row | {"at": at})
        added += result.rowcount  # type: ignore[attr-defined]
    return added
