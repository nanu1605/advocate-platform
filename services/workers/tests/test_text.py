"""The text pipeline and embeddings against the local stack (spec §12.4, F15): chunks in document_chunks, statuses on
the source, vectors from the embedder (its fake models, over its real HTTP API)."""

import uuid
from collections.abc import AsyncIterator, Callable
from typing import Any

import httpx
import pytest
from celery.exceptions import SoftTimeLimitExceeded
from conftest import Factory, _up, sql
from pdfs import make_pdf

from advocate_embedder.app import create_app
from advocate_embedder.fake import FakeModels
from advocate_shared import embedder, tasks
from advocate_shared.settings import get_settings
from advocate_workers import doctext, embed, storage, text
from advocate_workers.celery_app import EMBED_CHUNKS, ORDER_AI

ENGLISH = ["IN THE HIGH COURT OF MADHYA PRADESH AT INDORE", "1. Heard counsel for the petitioner on bail."]
LEGACY = ["U;k;ky; us vkns'k fn;k fd vkosnd dks tekur ij fjgk fd;k tk,A"]
PDF = make_pdf([[("Helvetica", ENGLISH), ("KrutiDev010", LEGACY)], [("Helvetica", ["2. List after four weeks."] * 9)]])


def no_ocr(_: bytes) -> str:
    raise AssertionError("no page here needs OCR")


@pytest.fixture
async def stored(make: Factory) -> AsyncIterator[Callable[..., Any]]:
    """`await stored(data, mime=..., status='ready', deleted=False)` -> (org, document id): a file in Storage."""
    if not _up(55321):
        pytest.skip("local Supabase not running (just dev)")
    paths: list[str] = []

    async def create(data: bytes, *, mime: str = "application/pdf", status: str = "ready", deleted: bool = False):
        org = await make.org()
        doc_id = str(uuid.uuid4())
        path = f"{org.id}/{doc_id}"
        await storage.put("documents", path, data, mime)
        paths.append(path)
        await sql(
            "insert into public.documents (id, org_id, title, storage_path, mime, size_bytes, upload_status, "
            "deleted_at) values (:id, :o, 'Bail order', :p, :m, :s, :st, case when :d then now() end)",
            id=doc_id, o=org.id, p=path, m=mime, s=len(data), st=status, d=deleted,
        )  # fmt: skip
        return org, doc_id

    yield create
    s = get_settings()
    key = s.supabase_service_role_key
    async with httpx.AsyncClient(headers={"Authorization": f"Bearer {key}", "apikey": key}) as c:
        await c.request("DELETE", f"{s.supabase_server_url}/storage/v1/object/documents", json={"prefixes": paths})


@pytest.fixture
async def court_order(make: Factory) -> AsyncIterator[str]:
    if not _up(55321):
        pytest.skip("local Supabase not running (just dev)")
    cnr = make.cnr()
    path = f"{cnr}/{uuid.uuid4().hex}.pdf"
    await storage.put("court-orders", path, PDF, "application/pdf")
    [row] = await sql(
        "insert into public.court_orders (cnr, provider_ref, storage_path) values (:c, 'o1', :p) returning id::text",
        c=cnr, p=path,
    )  # fmt: skip
    yield row["id"]
    await sql("delete from public.court_orders where id = :id", id=row["id"])
    s = get_settings()
    key = s.supabase_service_role_key
    async with httpx.AsyncClient(headers={"Authorization": f"Bearer {key}", "apikey": key}) as c:
        await c.request("DELETE", f"{s.supabase_server_url}/storage/v1/object/court-orders", json={"prefixes": [path]})


@pytest.fixture
def fake_embedder(monkeypatch: pytest.MonkeyPatch) -> embedder.Embedder:
    client = embedder.Embedder("http://embedder", transport=httpx.ASGITransport(app=create_app(FakeModels())))
    monkeypatch.setattr(embedder, "configured", lambda: client)
    return client


async def chunks_of(column: str, source_id: str) -> list[dict[str, Any]]:
    return await sql(
        f"select org_id::text, page_no, chunk_no, paras, text, embedding is not null as embedded "
        f"from public.document_chunks where {column} = :id order by page_no, chunk_no",
        id=source_id,
    )


async def test_a_document_is_read_into_chunks(stored, r, sent):
    org, doc_id = await stored(PDF)
    assert await text.extract(r, "document", doc_id, no_ocr) == "done"
    rows = await chunks_of("document_id", doc_id)
    assert [(c["org_id"], c["page_no"], c["chunk_no"], c["paras"]) for c in rows] == [
        (org.id, 1, 0, ["1"]),
        (org.id, 2, 0, ["2"]),  # it starts at paragraph 2
    ]
    assert "न्यायालय ने आदेश दिया कि आवेदक को जमानत पर रिहा किया जाए।" in rows[0]["text"]
    [doc] = await sql(
        "select text_status, pages, language, legacy_font_detected from public.documents where id = :id", id=doc_id
    )
    assert doc == {"text_status": "text", "pages": 2, "language": "en", "legacy_font_detected": True}  # mostly English
    assert sent == [(EMBED_CHUNKS, ())]

    # A redelivery or a swept duplicate: read already, so it costs a select and leaves the chunks (and vectors) be.
    assert await text.extract(r, "document", doc_id, no_ocr) == "skipped"
    assert await chunks_of("document_id", doc_id) == rows
    assert await r.get(f"text:document:{doc_id}") is None  # lock released


@pytest.mark.parametrize("error", [SoftTimeLimitExceeded(), MemoryError()])
async def test_a_run_that_breaks_or_runs_out_of_time_fails_for_good(stored, r, sent, error):
    _, doc_id = await stored(make_pdf([[]]))

    def ocr(_: bytes) -> str:
        raise error

    assert await text.extract(r, "document", doc_id, ocr) == "failed"
    [doc] = await sql("select text_status from public.documents where id = :id", id=doc_id)
    assert doc == {"text_status": "failed"}  # not 'none': the sweep leaves it
    assert await r.get(f"text:document:{doc_id}") is None


async def test_a_source_whose_runs_keep_getting_killed_fails(stored, r, sent, monkeypatch):
    seen: list[tuple[bytes | None, int]] = []
    get = storage.get

    async def spy(bucket: str, path: str) -> bytes | None:
        seen.append((await r.get(runs), await r.ttl(runs)))
        return await get(bucket, path)

    monkeypatch.setattr(storage, "get", spy)
    _, doc_id = await stored(PDF)
    runs = f"text-runs:document:{doc_id}"
    await r.set(runs, 2, ex=60)  # two runs killed outright (the hard limit, out of memory): their finally never ran
    assert await text.extract(r, "document", doc_id, no_ocr) == "done"
    [(count, ttl)] = seen
    assert count == b"3" and ttl > 86400  # counted while it runs
    assert await r.get(runs) is None  # and cleared once it ends

    _, doc_id = await stored(PDF)
    runs = f"text-runs:document:{doc_id}"
    await r.set(runs, 3, ex=60)
    assert await text.extract(r, "document", doc_id, no_ocr) == "failed"  # a fourth isn't started
    assert len(seen) == 1
    [doc] = await sql("select text_status from public.documents where id = :id", id=doc_id)
    assert doc == {"text_status": "failed"}
    assert await r.get(runs) is None and await r.get(f"text:document:{doc_id}") is None


async def test_a_scan_is_ocred_or_waits_for_ocr(stored, r, sent):
    _, doc_id = await stored(make_pdf([[]]))

    def none(_: bytes) -> str:
        raise doctext.OcrUnavailable

    assert await text.extract(r, "document", doc_id, none) == "ocr_pending"
    assert await chunks_of("document_id", doc_id) == []
    assert await text.sweep() >= 1 and (tasks.EXTRACT_TEXT, ("document", doc_id)) in sent

    assert await text.extract(r, "document", doc_id, lambda _: "आवेदक को ज़मानत पर रिहा किया जाए") == "done"
    [doc] = await sql("select text_status, language from public.documents where id = :id", id=doc_id)
    assert doc == {"text_status": "ocr_done", "language": "hi"}
    [row] = await chunks_of("document_id", doc_id)
    assert row["text"] == "आवेदक को ज़मानत पर रिहा किया जाए"


async def test_files_not_ready_deleted_missing_or_unreadable(stored, r, sent):
    for kwargs in ({"status": "pending"}, {"status": "quarantined"}, {"deleted": True}):
        _, doc_id = await stored(PDF, **kwargs)
        assert await text.extract(r, "document", doc_id, no_ocr) == "skipped", kwargs
    assert await text.extract(r, "document", str(uuid.uuid4()), no_ocr) == "skipped"

    _, doc_id = await stored(b"not a pdf")
    assert await text.extract(r, "document", doc_id, no_ocr) == "failed"
    _, missing = await stored(PDF)
    await sql("update public.documents set storage_path = 'nowhere' where id = :id", id=missing)
    assert await text.extract(r, "document", missing, no_ocr) == "failed"
    statuses = await sql("select text_status from public.documents where id in (:a, :b)", a=doc_id, b=missing)
    assert statuses == [{"text_status": "failed"}] * 2
    assert sent == []


async def test_another_run_holds_the_document(stored, r):
    _, doc_id = await stored(PDF)
    await r.set(f"text:document:{doc_id}", "other", ex=60)
    try:
        assert await text.extract(r, "document", doc_id, no_ocr) == "skipped"
    finally:
        await r.delete(f"text:document:{doc_id}")


async def test_a_court_orders_chunks_are_shared(court_order, r, sent):
    assert await text.extract(r, "court_order", court_order, no_ocr) == "done"
    rows = await chunks_of("court_order_id", court_order)
    assert [c["org_id"] for c in rows] == [None, None]
    [order] = await sql("select text_status, pages from public.court_orders where id = :id", id=court_order)
    assert order == {"text_status": "text", "pages": 2}
    assert sent == [(EMBED_CHUNKS, ()), (ORDER_AI, (court_order,))]  # then its summaries (summaries.py)


async def test_embeddings_fill_in_and_survive_an_outage(stored, r, sent, fake_embedder, monkeypatch):
    _, doc_id = await stored(PDF)
    await text.extract(r, "document", doc_id, no_ocr)
    assert await embed.embed_pending(r) >= 2
    assert [c["embedded"] for c in await chunks_of("document_id", doc_id)] == [True, True]
    [norm] = await sql(
        "select round(sum(x * x)::numeric, 3) as n from public.document_chunks, unnest(embedding::real[]) x "
        "where document_id = :id and page_no = 1",
        id=doc_id,
    )
    assert norm == {"n": 1}  # unit length

    _, doc_id = await stored(PDF)
    await text.extract(r, "document", doc_id, no_ocr)

    async def down(self, texts):
        raise httpx.ConnectError("down")

    monkeypatch.setattr(embedder.Embedder, "embed", down)
    assert await embed.embed_pending(r) == 0
    assert [c["embedded"] for c in await chunks_of("document_id", doc_id)] == [False, False]
    assert await r.get(embed.LOCK) is None


async def test_a_chunk_the_embedder_refuses_holds_up_no_one(stored, r, sent, fake_embedder, monkeypatch):
    org, other = await stored(PDF)
    [bad] = await sql(
        "insert into public.document_chunks (org_id, document_id, page_no, chunk_no, text, created_at) "
        "values (:o, :d, 1, 0, :t, '2000-01-01') returning id::text",
        o=org.id, d=other, t="A" * 9000,  # over the embedder's 8000 characters: a 422, first in line
    )  # fmt: skip
    _, doc_id = await stored(PDF)
    await text.extract(r, "document", doc_id, no_ocr)
    seen: list[str] = []
    real = embedder.Embedder.embed

    async def spy(self, texts):
        seen.extend(texts)
        return await real(self, texts)

    monkeypatch.setattr(embedder.Embedder, "embed", spy)
    try:
        assert await embed.embed_pending(r) >= 2
        assert [c["embedded"] for c in await chunks_of("document_id", doc_id)] == [True, True]
        assert await r.sismember(embed.REJECTED, bad["id"])
        seen.clear()
        await embed.embed_pending(r)
        assert "A" * 9000 not in seen  # set aside: never sent again
    finally:
        await r.srem(embed.REJECTED, bad["id"])


async def test_a_long_backlog_continues_in_a_new_run(stored, r, sent, fake_embedder):
    _, doc_id = await stored(PDF)
    await text.extract(r, "document", doc_id, no_ocr)
    sent.clear()
    assert await embed.embed_pending(r, run_s=-1) == 0  # out of time before the first batch
    assert sent == [(EMBED_CHUNKS, ())]


async def test_without_an_embedder_nothing_runs(r, monkeypatch):
    monkeypatch.setattr(get_settings(), "embedder_url", "")
    assert embedder.configured() is None
    assert await embed.embed_pending(r) == 0
