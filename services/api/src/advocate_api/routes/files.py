"""Documents and order files (spec §10.2, §4.3, §15.5): access is checked as the user, then Storage URLs are signed
with the service key. Order PDFs are fetched once per court order and shared (§11.5, ADR 0011)."""

import hashlib
from typing import Any, Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, Request
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_api import jobs, storage
from advocate_api.auth import CurrentClaims
from advocate_api.courts import court_data
from advocate_api.db import CurrentOrg, UserDb, service_db
from advocate_api.errors import ApiError
from advocate_api.idempotency import IdempotencyKey
from advocate_api.jobs import create_job
from advocate_api.ratelimit import limit, redis
from advocate_shared import retrieval
from advocate_shared.tasks import EXTRACT_TEXT, SCAN_DOCUMENT
from court_data.models import Capability

router = APIRouter(prefix="/v1")

MAX_BYTES = 52_428_800  # 50 MB per file (§4.3), also the bucket's limit
UPLOAD_TTL_S = 7200  # Supabase's fixed signed-upload lifetime
DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
EXTENSIONS = {"application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png", DOCX: "docx"}
FETCH_LOCK_S = 60
# Deletes the lock only if it is still ours: a fetch slower than FETCH_LOCK_S may have lost it to another.
RELEASE_LOCK = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end return 0"


class UploadIn(BaseModel):
    title: str = Field(min_length=1, max_length=300)
    kind: Literal["pleading", "order", "evidence", "annexure", "correspondence", "other"]
    matter_id: UUID | None = None
    mime: Literal[
        "application/pdf",
        "image/jpeg",
        "image/png",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ]
    size_bytes: int = Field(ge=1, le=MAX_BYTES)


class UploadUrl(BaseModel):
    document_id: UUID
    upload_url: str
    expires_in_s: int


class Completed(BaseModel):
    document_id: UUID
    upload_status: str
    job_id: UUID


class SignedUrl(BaseModel):
    url: str
    expires_in_s: int


class SearchIn(BaseModel):
    query: str = Field(min_length=2, max_length=200)
    matter_id: UUID | None = None


class SearchHit(BaseModel):
    document_id: UUID | None  # an uploaded document, or
    order_id: UUID | None  # a court order (opened as /cases/{matter_id}/orders/{order_id})
    matter_id: UUID | None
    title: str
    page: int
    paras: list[str]
    snippet: str


class SearchOut(BaseModel):
    hits: list[SearchHit]


@router.post("/documents/upload-url", status_code=201)
async def upload_url(db: UserDb, org: CurrentOrg, claims: CurrentClaims, body: UploadIn) -> UploadUrl:
    """Start an upload: PUT the file to `upload_url` with the declared `mime` as Content-Type, then call
    `/complete`. A file of another type is refused there, and the document needs a new upload URL."""
    await limit(f"upload:{claims['sub']}", 60, 60)
    if body.matter_id:
        matter = await db.execute(
            text("select 1 from public.matters where id = :m and org_id = :o and deleted_at is null"),
            {"m": body.matter_id, "o": org.org_id},
        )
        if matter.scalar_one_or_none() is None:
            raise ApiError(404, "NOT_FOUND", "Matter not found")
    document_id = uuid4()
    path = f"{org.org_id}/{document_id}"
    await db.execute(
        text(
            "insert into public.documents (id, org_id, matter_id, title, kind, storage_path, mime, size_bytes) "
            "values (:id, :o, :m, :t, :k, :p, :mime, :s)"
        ),
        {
            "id": document_id,
            "o": org.org_id,
            "m": body.matter_id,
            "t": body.title,
            "k": body.kind,
            "p": path,
            "mime": body.mime,
            "s": body.size_bytes,
        },
    )
    return UploadUrl(
        document_id=document_id, upload_url=await storage.upload_url("documents", path), expires_in_s=UPLOAD_TTL_S
    )


async def _document(db: AsyncConnection, org_id: UUID, document_id: UUID) -> dict[str, Any]:
    row = (
        (
            await db.execute(
                text(
                    "select storage_path, mime, upload_status from public.documents "
                    "where id = :id and org_id = :o and deleted_at is null"
                ),
                {"id": document_id, "o": org_id},
            )
        )
        .mappings()
        .one_or_none()
    )
    if row is None:
        raise ApiError(404, "NOT_FOUND", "Document not found")
    return dict(row)


@router.post("/documents/{document_id}/complete", status_code=202)
async def complete_upload(
    idem: IdempotencyKey, db: UserDb, org: CurrentOrg, request: Request, document_id: UUID
) -> Completed:
    lock = "select 1 from public.documents where id = :id and org_id = :o for update"  # one complete at a time
    await db.execute(text(lock), {"id": document_id, "o": org.org_id})
    doc = await _document(db, org.org_id, document_id)
    if doc["upload_status"] != "pending":
        raise ApiError(409, "ALREADY_COMPLETE", "This upload is already complete")
    # Any member's running scan counts, and RLS shows a member only their own jobs: look it up server-side.
    async with service_db() as c:
        scanning = await c.execute(
            text(
                "select id from public.jobs where org_id = :o and kind = 'scan_document' "
                "and input->>'document_id' = :d and status in ('queued', 'running') limit 1"
            ),
            {"o": org.org_id, "d": str(document_id)},
        )
        job_id = scanning.scalar_one_or_none()
    if job_id:
        return idem.keep(Completed(document_id=document_id, upload_status="pending", job_id=job_id))
    stored = await storage.info("documents", doc["storage_path"])
    if stored is None:
        raise ApiError(409, "UPLOAD_MISSING", "The file has not been uploaded")
    if stored["size"] > MAX_BYTES:
        raise ApiError(413, "FILE_TOO_LARGE", "Files can be up to 50 MB", details={"max_bytes": MAX_BYTES})
    # Storage keeps the Content-Type the client sent; it must be the type we validated.
    sent = (stored.get("content_type") or "").split(";")[0].strip().lower()
    if sent != doc["mime"]:
        raise ApiError(415, "UNSUPPORTED_FILE_TYPE", "The file doesn't match its declared type", details={"mime": sent})
    await db.execute(
        text("update public.documents set size_bytes = :s where id = :id"), {"s": stored["size"], "id": document_id}
    )
    job_id = await create_job(
        db, request, task=SCAN_DOCUMENT, kind="scan_document", org_id=org.org_id, job_input={"document_id": document_id}
    )
    return idem.keep(Completed(document_id=document_id, upload_status="pending", job_id=job_id))


@router.get("/documents/{document_id}/download-url")
async def document_download_url(db: UserDb, org: CurrentOrg, document_id: UUID) -> SignedUrl:
    doc = await _document(db, org.org_id, document_id)
    if doc["upload_status"] == "pending":
        raise ApiError(409, "DOCUMENT_NOT_READY", "This document is still being checked", retryable=True)
    if doc["upload_status"] == "quarantined":
        raise ApiError(409, "DOCUMENT_QUARANTINED", "This file failed the safety check")
    ext = EXTENSIONS.get(doc["mime"] or "")
    filename = f"{document_id}.{ext}" if ext else str(document_id)  # no titles in URLs (§10.1); the app names the file
    url = await storage.download_url("documents", doc["storage_path"], filename)
    return SignedUrl(url=url, expires_in_s=storage.DOWNLOAD_TTL_S)


async def _court_order(court_order_id: UUID) -> dict[str, Any]:
    async with service_db() as c:
        row = await c.execute(
            text("select cnr, provider_ref, storage_path from public.court_orders where id = :id"),
            {"id": court_order_id},
        )
        return dict(row.mappings().one())


@router.post("/documents/search")
async def search_documents(db: UserDb, org: CurrentOrg, claims: CurrentClaims, body: SearchIn) -> SearchOut:
    """Search inside the organisation's documents and court orders, scans included (spec F06, F15): the most relevant
    pages first. The query goes in the body, never the URL: it can name parties (§15.6)."""
    await limit(f"doc-search:{claims['sub']}", 30, 60)
    hits = await retrieval.search(db, org.org_id, body.query, matter_id=body.matter_id)
    return SearchOut(
        hits=[
            SearchHit(
                document_id=h.document_id,
                order_id=h.order_id,
                matter_id=h.matter_id,
                title=h.title,
                page=h.page_no,
                paras=h.paras,
                snippet=retrieval.snippet(h.text, body.query),
            )
            for h in hits
        ]
    )


@router.get("/orders/{order_id}/pdf-url")
async def order_pdf_url(db: UserDb, org: CurrentOrg, order_id: UUID) -> SignedUrl:
    row = (
        await db.execute(
            text("select court_order_id from public.orders where id = :id and org_id = :o and deleted_at is null"),
            {"id": order_id, "o": org.org_id},
        )
    ).one_or_none()
    if row is None:
        raise ApiError(404, "NOT_FOUND", "Order not found")
    court_order_id = row.court_order_id
    if court_order_id is None:
        raise ApiError(404, "ORDER_PDF_UNAVAILABLE", "No court copy of this order")
    path = (await _court_order(court_order_id))["storage_path"] or await _fetch_order_pdf(org.org_id, court_order_id)
    return SignedUrl(url=await storage.download_url("court-orders", path), expires_in_s=storage.DOWNLOAD_TTL_S)


async def _fetch_order_pdf(org_id: UUID, court_order_id: UUID) -> str:
    """Fetch, store and record one court order's PDF, costed to `org_id`. One fetch at a time per court order."""
    lock, token = f"order-pdf:{court_order_id}", uuid4().hex
    if not await redis().set(lock, token, nx=True, ex=FETCH_LOCK_S):
        raise ApiError(409, "ORDER_PDF_FETCHING", "This order is being fetched", retryable=True)
    try:
        order = await _court_order(court_order_id)  # a fetch may have finished since the first read
        if order["storage_path"]:
            return order["storage_path"]
        cnr, ref = order["cnr"], order["provider_ref"]
        async with court_data(org_id) as router:
            pdf = await router.run(
                Capability.ORDER_PDF, lambda p: p.get_order_pdf(cnr, ref), cnr=cnr, org_id=str(org_id)
            )
        sha = hashlib.sha256(pdf).hexdigest()
        path = f"{cnr}/{sha}.pdf"
        await storage.put("court-orders", path, pdf, "application/pdf")
        async with service_db() as c:
            await c.execute(
                text("update public.court_orders set storage_path = :p, sha256 = :s where id = :id"),
                {"p": path, "s": sha, "id": court_order_id},
            )
        await jobs.enqueue(EXTRACT_TEXT, "court_order", court_order_id)  # its text, for search and AI
        return path
    finally:
        await redis().register_script(RELEASE_LOCK)(keys=[lock], args=[token])
