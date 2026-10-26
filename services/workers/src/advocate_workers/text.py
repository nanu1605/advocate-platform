"""The text pipeline (spec §12.4, F15, F28): a document's or a court order's text, page by page, cut into chunks in
document_chunks for search and AI (doctext.py does the reading). It runs when a document's malware scan passes and
when a court order's PDF is stored; an hourly sweep picks up the rest: OCR that was unavailable, a lost task, and
files from before P2. The embeddings come after (embed.py).

A document's chunks belong to its organisation; a court order's are shared by every organisation tracking its CNR
(ADR 0019). A source is read once: a redelivered or swept duplicate is skipped unless its text is still unread or
waiting for OCR. A file that fails in an unexpected way, runs past SOFT_LIMIT_S, or whose runs are killed outright
MAX_RUNS times, is marked failed, so the sweep doesn't retry it forever."""

from typing import Any
from uuid import uuid4

import httpx
import structlog
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError

from advocate_shared import tasks
from advocate_workers import db, doctext, jobs, storage
from advocate_workers.celery_app import EMBED_CHUNKS, TEXT_SWEEP, app

log = structlog.get_logger()

SOFT_LIMIT_S = 3 * 3600  # a 250-page scanned paperbook at ~20 s a page, with room to spare
HARD_LIMIT_S = SOFT_LIMIT_S + 300  # celery_app's visibility_timeout stays above this
LOCK_TTL_S = HARD_LIMIT_S  # a run killed at the hard limit (stuck in C) or out of memory is retried after this...
MAX_RUNS = 3  # ...until this many such runs in a row: their count, kept RUNS_TTL_S, is cleared only by a run that ends
RUNS_TTL_S = 2 * 86400
SWEEP_BATCH = 50

SOURCE = {  # only while its text is unread or waits for OCR
    "document": "select storage_path, mime, org_id::text from public.documents where id = :id "
    "and upload_status = 'ready' and deleted_at is null and text_status in ('none', 'ocr_pending')",
    "court_order": "select storage_path, 'application/pdf' as mime, null as org_id from public.court_orders "
    "where id = :id and storage_path is not null and text_status in ('none', 'ocr_pending')",
}
BUCKET = {"document": "documents", "court_order": "court-orders"}
COLUMN = {"document": "document_id", "court_order": "court_order_id"}
STATUS = {
    "document": "update public.documents set text_status = :s, pages = coalesce(:p, pages), language = :l, "
    "legacy_font_detected = :k where id = :id",
    "court_order": "update public.court_orders set text_status = :s, pages = coalesce(:p, pages) where id = :id",
}
INSERT = """
insert into public.document_chunks (org_id, document_id, court_order_id, page_no, chunk_no, paras, text)
values (:org, :document_id, :court_order_id, :page_no, :chunk_no, :paras, :text)
"""


async def _status(kind: str, source_id: str, status: str, **values: Any) -> None:
    async with db.engine().begin() as c:
        await c.execute(text(STATUS[kind]), {"id": source_id, "s": status, "p": None, "l": None, "k": False} | values)


async def extract(r: Redis, kind: str, source_id: str, ocr: doctext.Ocr = doctext.tesseract) -> str:
    """Read one source's text into chunks. Returns done, skipped (gone, not ready, already read, or another run has
    it), ocr_pending (no OCR engine here; the sweep tries again) or failed (an unreadable or missing file, or any
    other error, the soft time limit included, or MAX_RUNS runs before this one killed outright)."""
    lock, runs, token = f"text:{kind}:{source_id}", f"text-runs:{kind}:{source_id}", uuid4().hex
    if not await r.set(lock, token, nx=True, ex=LOCK_TTL_S):
        return "skipped"
    try:
        async with db.engine().connect() as c:
            found = await db.rows(c, SOURCE[kind], id=source_id)
        if not found:
            return "skipped"
        if await r.incr(runs) > MAX_RUNS:
            log.error("text_failed", kind=kind, id=source_id, error="killed")
            await _status(kind, source_id, "failed")
            return "failed"
        await r.expire(runs, RUNS_TTL_S)
        src = found[0]
        try:
            data = await storage.get(BUCKET[kind], src["storage_path"])
        except httpx.HTTPError:
            log.warning("text_storage_unavailable", kind=kind, id=source_id)
            return "skipped"  # the sweep tries again
        if data is None:
            await _status(kind, source_id, "failed")
            return "failed"
        try:
            with structlog.contextvars.bound_contextvars(kind=kind, id=source_id):  # on doctext's page logs
                reading = doctext.read(data, src["mime"], ocr)
        except doctext.OcrUnavailable:
            log.warning("ocr_unavailable", kind=kind, id=source_id)
            await _status(kind, source_id, "ocr_pending")
            return "ocr_pending"
        except doctext.Unreadable:
            await _status(kind, source_id, "failed")
            return "failed"
        rows = [
            {
                "org": src["org_id"],
                "document_id": source_id if kind == "document" else None,
                "court_order_id": source_id if kind == "court_order" else None,
                "page_no": ch.page_no,
                "chunk_no": ch.chunk_no,
                "paras": ch.paras,
                "text": ch.text.replace("\x00", ""),
            }
            for ch in doctext.chunks(reading.pages)
        ]
        try:
            async with db.engine().begin() as c:
                delete = f"delete from public.document_chunks where {COLUMN[kind]} = :id"  # noqa: S608
                await c.execute(text(delete), {"id": source_id})
                if rows:
                    await c.execute(text(INSERT), rows)
                await c.execute(
                    text(STATUS[kind]),
                    {
                        "id": source_id,
                        "s": "ocr_done" if reading.ocr_pages else "text",
                        "p": None if src["mime"] == doctext.DOCX else len(reading.pages),
                        "l": doctext.language(reading.pages),
                        "k": reading.legacy_font,
                    },
                )
        except IntegrityError:
            return "skipped"  # deleted while it was read
    except Exception as e:  # SoftTimeLimitExceeded too; the type only, an error's message may quote the file
        log.error("text_failed", kind=kind, id=source_id, error=type(e).__name__)
        await _status(kind, source_id, "failed")
        return "failed"
    finally:  # never reached by a run killed outright: its count stays
        await r.delete(runs)
        await r.register_script(jobs.RELEASE)(keys=[lock], args=[token])
    if rows:
        jobs.send(EMBED_CHUNKS)
    log.info("text_extracted", kind=kind, id=source_id, pages=len(reading.pages), chunks=len(rows))
    return "done"


SWEEP = """
(select 'document' as kind, id::text from public.documents
 where upload_status = 'ready' and deleted_at is null and text_status in ('none', 'ocr_pending')
 order by updated_at limit :n)
union all
(select 'court_order', id::text from public.court_orders
 where storage_path is not null and text_status in ('none', 'ocr_pending')
 order by updated_at limit :n)
"""


async def sweep() -> int:
    """Send the extraction for sources whose text was never read, or waits for OCR. Returns how many."""
    async with db.engine().connect() as c:
        due = await db.rows(c, SWEEP, n=SWEEP_BATCH)
    for row in due:
        jobs.send(tasks.EXTRACT_TEXT, row["kind"], row["id"])
    return len(due)


@app.task(name=tasks.EXTRACT_TEXT, soft_time_limit=SOFT_LIMIT_S, time_limit=HARD_LIMIT_S)
def extract_text(kind: str, source_id: str) -> str:
    return jobs.run_task(lambda r: extract(r, kind, source_id))


@app.task(name=TEXT_SWEEP)
def text_sweep() -> int:
    return jobs.run_task(lambda _: sweep())
