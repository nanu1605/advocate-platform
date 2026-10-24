"""scan_document against a fake clamd (an asyncio TCP server speaking INSTREAM) and the local Storage."""

import asyncio
import hashlib
import socket
import struct
import uuid
from collections.abc import AsyncIterator, Callable
from types import SimpleNamespace
from typing import Any, cast

import httpx
import pytest
from celery import Task
from conftest import Factory, Org, _up, sql
from structlog.testing import capture_logs

from advocate_shared.settings import get_settings
from advocate_workers import jobs, scan, storage

MARKER = b"FAKE-MALWARE-MARKER"  # never the real EICAR string: antivirus on a dev machine would eat this file


class FakeClamd:
    """Speaks clamd's zINSTREAM: collects the chunks, then replies with `verdict(data)`."""

    def __init__(self, verdict: Callable[[bytes], str]) -> None:
        self.verdict = verdict
        self.hang = False  # take the stream, never answer
        self.streams: list[bytes] = []

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        assert await reader.readuntil(b"\0") == b"zINSTREAM\0"
        data = b""
        while size := struct.unpack(">I", await reader.readexactly(4))[0]:
            data += await reader.readexactly(size)
        self.streams.append(data)
        if self.hang:
            await reader.read()  # until the client gives up
        else:
            writer.write(self.verdict(data).encode() + b"\0")
            await writer.drain()
        writer.close()


def _verdict(data: bytes) -> str:
    return "stream: Eicar-Test-Signature FOUND" if MARKER in data else "stream: OK"


@pytest.fixture
async def clamd(monkeypatch: pytest.MonkeyPatch) -> AsyncIterator[FakeClamd]:
    fake = FakeClamd(_verdict)
    server = await asyncio.start_server(fake.handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    monkeypatch.setattr(get_settings(), "clamav_url", f"tcp://127.0.0.1:{port}")
    monkeypatch.setattr(scan, "CHUNK", 7)  # several chunks even for a small file
    yield fake
    server.close()
    await server.wait_closed()


@pytest.fixture
async def upload(make: Factory) -> AsyncIterator[Callable[..., Any]]:
    """`await upload(data, status='pending')` -> (org, document id, job id): a document stored as the API stores it,
    with its scan_document job."""
    if not _up(55321):
        pytest.skip("local Supabase not running (just dev)")
    paths: list[str] = []

    async def create(data: bytes, status: str = "pending") -> tuple[Org, str, str]:
        org = await make.org()
        doc_id = str(uuid.uuid4())
        path = f"{org.id}/{doc_id}"
        await storage.put("documents", path, data, "application/pdf")
        paths.append(path)
        await sql(
            "insert into public.documents (id, org_id, title, storage_path, mime, size_bytes, upload_status) "
            "values (:id, :o, 'Ramesh Kumar affidavit', :p, 'application/pdf', :s, :st)",
            id=doc_id, o=org.id, p=path, s=len(data), st=status,
        )  # fmt: skip
        job_id = await make.job(org, "scan_document", {"document_id": doc_id})
        return org, doc_id, job_id

    yield create
    s = get_settings()
    key = s.supabase_service_role_key
    async with httpx.AsyncClient(headers={"Authorization": f"Bearer {key}", "apikey": key}) as c:
        await c.request("DELETE", f"{s.supabase_server_url}/storage/v1/object/documents", json={"prefixes": paths})


async def _state(doc_id: str, job_id: str) -> tuple[dict[str, Any], dict[str, Any]]:
    [doc] = await sql("select upload_status, sha256 from public.documents where id = :id", id=doc_id)
    [job] = await sql("select status, result, error from public.jobs where id = :id", id=job_id)
    return doc, job


def _task(retries: int) -> Any:
    """A bound Celery task as run_job sees it, on its `retries`th retry of 5."""
    task = SimpleNamespace(request=SimpleNamespace(retries=retries), max_retries=5, countdowns=[])
    task.retry = lambda countdown: task.countdowns.append(countdown) or RuntimeError("retry")
    return task


async def test_clean_file_becomes_ready_with_its_sha256(upload, clamd: FakeClamd):
    data = b"%PDF-1.4 a clean petition, longer than one chunk"
    _, doc_id, job_id = await upload(data)
    await jobs.run(job_id, scan.scan)
    doc, job = await _state(doc_id, job_id)
    assert clamd.streams == [data]  # every chunk arrived, in order
    assert doc == {"upload_status": "ready", "sha256": hashlib.sha256(data).hexdigest()}
    assert job == {"status": "done", "result": {"upload_status": "ready"}, "error": None}


async def test_infected_file_is_quarantined_and_only_the_signature_logged(upload, clamd: FakeClamd):
    data = b"%PDF-1.4 " + MARKER
    _, doc_id, job_id = await upload(data)
    with capture_logs() as logs:
        await jobs.run(job_id, scan.scan)
    doc, job = await _state(doc_id, job_id)
    assert doc == {"upload_status": "quarantined", "sha256": hashlib.sha256(data).hexdigest()}
    assert job["status"] == "done" and job["result"] == {"upload_status": "quarantined"}
    [entry] = [e for e in logs if e["event"] == "document_quarantined"]
    assert entry["signature"] == "Eicar-Test-Signature"
    assert "Ramesh" not in repr(logs)  # never the title


async def test_scanner_down_keeps_document_pending_and_retries_then_fails(upload, monkeypatch):
    with socket.socket() as s:  # a port nothing listens on
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    monkeypatch.setattr(get_settings(), "clamav_url", f"tcp://127.0.0.1:{port}")
    _, doc_id, job_id = await upload(b"%PDF-1.4 waiting for the scanner")
    with pytest.raises(jobs.RetryLater, match="SCANNER_UNAVAILABLE"):
        await jobs.run(job_id, scan.scan)
    assert (await _state(doc_id, job_id))[0]["upload_status"] == "pending"

    # Through the Celery glue (run_job uses asyncio.run, so off this loop): a retry with backoff, then the last one.
    first = _task(retries=0)
    with pytest.raises(RuntimeError, match="retry"):
        await asyncio.to_thread(jobs.run_job, cast(Task, first), job_id, scan.scan)
    assert first.countdowns == [30]
    await asyncio.to_thread(jobs.run_job, cast(Task, _task(retries=5)), job_id, scan.scan)
    doc, job = await _state(doc_id, job_id)
    assert doc == {"upload_status": "pending", "sha256": None}  # fail closed: never ready without a verdict
    assert job["status"] == "failed" and job["error"] == "SCANNER_UNAVAILABLE"


async def test_clamd_error_reply_is_not_a_verdict(upload, clamd: FakeClamd):
    clamd.verdict = lambda data: "INSTREAM size limit exceeded. ERROR"
    _, doc_id, job_id = await upload(b"%PDF-1.4 too big for this clamd")
    with pytest.raises(jobs.RetryLater, match="SCANNER_UNAVAILABLE"):
        await jobs.run(job_id, scan.scan)
    assert (await _state(doc_id, job_id))[0]["upload_status"] == "pending"


async def test_no_verdict_after_the_whole_file_fails_at_once(upload, clamd: FakeClamd, monkeypatch):
    # clamd answers past its own scan limits (AlertExceedsMax), so silence after the stream isn't an outage to retry:
    # retrying would hold a worker and a clamd thread again and again for a file built to be slow.
    clamd.hang = True
    monkeypatch.setattr(scan, "VERDICT_TIMEOUT_S", 0.2)
    _, doc_id, job_id = await upload(b"%PDF-1.4 built to keep clamd busy")
    with capture_logs() as logs:
        await jobs.run(job_id, scan.scan)  # no RetryLater
    doc, job = await _state(doc_id, job_id)
    assert doc == {"upload_status": "pending", "sha256": None}  # never ready without a verdict
    assert (job["status"], job["error"]) == ("failed", "SCANNER_UNAVAILABLE")
    assert [e["event"] for e in logs if e["log_level"] == "error"] == ["scanner_no_verdict"]


async def test_unconfigured_scanner_fails_closed(upload, clamd: FakeClamd, monkeypatch):
    monkeypatch.setattr(get_settings(), "clamav_url", "")
    _, doc_id, job_id = await upload(b"%PDF-1.4 no scanner configured")
    with pytest.raises(jobs.RetryLater, match="SCANNER_UNAVAILABLE"):
        await jobs.run(job_id, scan.scan)
    doc, job = await _state(doc_id, job_id)
    assert doc["upload_status"] == "pending" and job["status"] == "running"  # the Celery retry resumes it
    assert clamd.streams == []


@pytest.mark.parametrize("status", ["ready", "quarantined"])
async def test_scanned_documents_are_left_alone(upload, clamd: FakeClamd, status: str):
    _, doc_id, job_id = await upload(b"%PDF-1.4 already scanned", status=status)
    await jobs.run(job_id, scan.scan)
    doc, job = await _state(doc_id, job_id)
    assert doc == {"upload_status": status, "sha256": None}
    assert job["status"] == "done" and job["result"] == {"upload_status": status}
    assert clamd.streams == []
