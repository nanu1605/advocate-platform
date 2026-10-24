"""Malware scan of uploaded documents with clamd (SCAN_DOCUMENT job, spec §4.3). The file goes from Storage to clamd
over the INSTREAM protocol; `stream: OK` makes the document `ready`, a `FOUND` verdict `quarantined`. Fail closed:
with the scanner unconfigured or down the document stays `pending` (the API serves no download link for it), the
task retries with backoff and the job finally fails with SCANNER_UNAVAILABLE. clamd answers a file past its scan
limits (size, nesting, MaxScanTime) with a FOUND verdict (AlertExceedsMax, infra/docker/compose.yml), so no verdict
after the whole file went over is no outage: the job fails at once, the document still pending."""

import asyncio
import hashlib
import struct
from contextlib import suppress
from typing import Any
from urllib.parse import urlsplit

import httpx
import structlog
from celery import Task
from redis.asyncio import Redis
from sqlalchemy import text

from advocate_shared import tasks
from advocate_shared.settings import get_settings
from advocate_workers import db, jobs, storage
from advocate_workers.celery_app import app

log = structlog.get_logger()

UNAVAILABLE = "SCANNER_UNAVAILABLE"
CHUNK = 1 << 20  # INSTREAM chunk; clamd's StreamMaxLength caps the whole stream (60M in infra/docker/compose.yml)
SEND_TIMEOUT_S = 60  # connect, and stream a 50 MB file
VERDICT_TIMEOUT_S = 150  # longer than clamd's MaxScanTime (120 s), so its own limit verdict arrives first


class NoVerdict(Exception):
    """clamd took the whole stream but gave no verdict in time."""


async def clamd_scan(url: str, data: bytes) -> str:
    """clamd's verdict on `data` (url tcp://host:port): 'stream: OK', 'stream: <signature> FOUND' or '<reason> ERROR'.
    Raises OSError (TimeoutError included) or IncompleteReadError when clamd can't be reached or hangs up, and
    NoVerdict when it took the file but never answered."""
    target = urlsplit(url)
    async with asyncio.timeout(SEND_TIMEOUT_S):
        reader, writer = await asyncio.open_connection(target.hostname, target.port or 3310)
    try:
        async with asyncio.timeout(SEND_TIMEOUT_S):
            writer.write(b"zINSTREAM\0")  # z: replies end with NUL
            for i in range(0, len(data), CHUNK):
                chunk = data[i : i + CHUNK]
                writer.write(struct.pack(">I", len(chunk)) + chunk)
                await writer.drain()
            writer.write(struct.pack(">I", 0))  # end of stream
            await writer.drain()
        try:
            async with asyncio.timeout(VERDICT_TIMEOUT_S):
                return (await reader.readuntil(b"\0"))[:-1].decode().strip()
        except TimeoutError as e:
            raise NoVerdict from e
    finally:
        writer.close()
        with suppress(OSError):
            await writer.wait_closed()


async def scan(job: jobs.Job, r: Redis) -> dict[str, Any]:
    document_id = job.input["document_id"]
    async with db.engine().connect() as c:
        found = await db.rows(
            c,
            "select storage_path, upload_status from public.documents where id = :id and org_id = :o",
            id=document_id, o=job.org_id,
        )  # fmt: skip
    if not found or found[0]["upload_status"] != "pending":
        return {"upload_status": found[0]["upload_status"] if found else None}  # gone, or a rerun after the verdict
    url = get_settings().clamav_url
    if not url:
        log.error("scanner_unconfigured", document_id=document_id)
        raise jobs.RetryLater(UNAVAILABLE)
    try:
        data = await storage.get("documents", found[0]["storage_path"])
    except httpx.HTTPError as e:
        raise jobs.RetryLater(UNAVAILABLE) from e  # no file to scan is the same outage for the user
    if data is None:
        raise jobs.JobFailed("UPLOAD_MISSING")
    try:
        verdict = await clamd_scan(url, data)
    except NoVerdict as e:
        log.error("scanner_no_verdict", document_id=document_id)
        raise jobs.JobFailed(UNAVAILABLE) from e
    except (OSError, asyncio.IncompleteReadError) as e:
        log.warning("scanner_unavailable", document_id=document_id, error=repr(e))
        raise jobs.RetryLater(UNAVAILABLE) from e
    if verdict.endswith(" FOUND"):
        status = "quarantined"
        # The signature only: titles and file names often name parties (spec §7.2).
        signature = verdict.removeprefix("stream:").removesuffix(" FOUND").strip()
        log.warning("document_quarantined", document_id=document_id, signature=signature)
    elif verdict.endswith(" OK"):
        status = "ready"
    else:
        log.error("scanner_error", document_id=document_id, reply=verdict)
        raise jobs.RetryLater(UNAVAILABLE)
    async with db.engine().begin() as c:
        await c.execute(
            text(
                "update public.documents set upload_status = :s, sha256 = :h "
                "where id = :id and upload_status = 'pending'"
            ),
            {"s": status, "h": hashlib.sha256(data).hexdigest(), "id": document_id},
        )
    return {"upload_status": status}


@app.task(name=tasks.SCAN_DOCUMENT, bind=True, max_retries=5)
def scan_document(self: Task, job_id: str) -> None:
    jobs.run_job(self, job_id, scan)
