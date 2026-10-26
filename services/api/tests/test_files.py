"""Document uploads (signed upload, complete -> scan job, signed download) and shared order PDFs, against real local
Storage."""

import uuid

import httpx
import pytest

from advocate_api import storage
from advocate_api.ratelimit import redis
from advocate_api.routes.files import MAX_BYTES
from advocate_shared.tasks import EXTRACT_TEXT, SCAN_DOCUMENT

from .conftest import make_team, sql

PHONES = {"owner": ("919999900024", "owner"), "junior": ("919999900025", "junior")}
OTHER = {"other": ("919999900027", "owner")}
PDF = b"%PDF-1.4\n% test document\n%%EOF\n"
CNR = "TEST010000012024"


@pytest.fixture(scope="module")
async def team():
    return await make_team(PHONES)


@pytest.fixture(scope="module")
async def other():
    return await make_team(OTHER)


@pytest.fixture(scope="module")
async def matter_id(team) -> str:
    [row] = await sql(
        "insert into public.matters (org_id, cnr, source, tracking) values (:o, :c, 'cnr', 'manual') "
        "returning id::text",
        o=team.org_id, c=CNR,
    )  # fmt: skip
    return row["id"]


def idem() -> dict[str, str]:
    return {"Idempotency-Key": f"key-{uuid.uuid4()}"}


def new_doc(**fields: object) -> dict[str, object]:
    return {
        "title": "Written statement",
        "kind": "pleading",
        "mime": "application/pdf",
        "size_bytes": len(PDF),
    } | fields


async def test_upload_complete_download(api, team, matter_id, enqueued):
    declared = new_doc(matter_id=matter_id, size_bytes=len(PDF) + 100)  # the stored size wins
    r = await api.post("/v1/documents/upload-url", headers=team.h("junior"), json=declared)
    assert r.status_code == 201
    doc_id, upload_url = r.json()["document_id"], r.json()["upload_url"]
    assert r.json()["expires_in_s"] == 7200
    [row] = await sql(
        "select storage_path, upload_status, matter_id::text, uploaded_by::text from public.documents where id = :id",
        id=doc_id,
    )
    assert row == {
        "storage_path": f"{team.org_id}/{doc_id}",
        "upload_status": "pending",
        "matter_id": matter_id,
        "uploaded_by": team.users["junior"],
    }
    async with httpx.AsyncClient() as http:
        put = await http.put(upload_url, content=PDF, headers={"Content-Type": "application/pdf"})
        assert put.status_code == 200, put.text

        download = f"/v1/documents/{doc_id}/download-url"
        early = await api.get(download, headers=team.h("junior"))
        assert early.status_code == 409 and early.json()["error"]["code"] == "DOCUMENT_NOT_READY"

        complete = f"/v1/documents/{doc_id}/complete"
        r = await api.post(complete, headers=team.h("junior", **idem()))
        assert r.status_code == 202, r.text
        assert r.json()["document_id"] == doc_id and r.json()["upload_status"] == "pending"
        job_id = r.json()["job_id"]
        assert enqueued == [(SCAN_DOCUMENT, job_id)]
        [job] = await sql("select kind, input from public.jobs where id = :id", id=job_id)
        assert job == {"kind": "scan_document", "input": {"document_id": doc_id}}
        [row] = await sql("select size_bytes, mime from public.documents where id = :id", id=doc_id)
        assert row == {"size_bytes": len(PDF), "mime": "application/pdf"}
        assert (await api.get(download, headers=team.h("junior"))).status_code == 409  # waits for the scan

        r = await api.post(complete, headers=team.h("junior", **idem()))  # a fresh key while the scan is queued
        assert r.status_code == 202 and r.json()["job_id"] == job_id
        assert enqueued == [(SCAN_DOCUMENT, job_id)]

        await sql("update public.documents set upload_status = 'ready' where id = :id", id=doc_id)
        r = await api.get(download, headers=team.h("owner"))
        assert r.status_code == 200 and r.json()["expires_in_s"] == 300
        assert "Written" not in r.json()["url"]  # titles name parties: never in URLs
        file = await http.get(r.json()["url"])
        assert file.status_code == 200 and file.content == PDF
        assert f"{doc_id}.pdf" in file.headers["content-disposition"]

    again = await api.post(complete, headers=team.h("junior", **idem()))
    assert again.status_code == 409 and again.json()["error"]["code"] == "ALREADY_COMPLETE"

    await sql("update public.documents set upload_status = 'quarantined' where id = :id", id=doc_id)
    r = await api.get(download, headers=team.h("owner"))
    assert r.status_code == 409 and r.json()["error"]["code"] == "DOCUMENT_QUARANTINED"


@pytest.mark.parametrize(("content_type", "status"), [("image/png", 415), ("Application/PDF; charset=utf-8", 202)])
async def test_complete_checks_uploaded_type(api, team, enqueued, content_type, status):
    r = await api.post("/v1/documents/upload-url", headers=team.h("owner"), json=new_doc())
    doc_id = r.json()["document_id"]
    async with httpx.AsyncClient() as http:
        put = await http.put(r.json()["upload_url"], content=PDF, headers={"Content-Type": content_type})
    assert put.status_code == 200, put.text  # the bucket allows png, so only the declared type catches it

    r = await api.post(f"/v1/documents/{doc_id}/complete", headers=team.h("owner", **idem()))
    assert r.status_code == status, r.text
    [row] = await sql("select upload_status, mime from public.documents where id = :id", id=doc_id)
    assert row == {"upload_status": "pending", "mime": "application/pdf"}
    if status == 415:
        assert r.json()["error"]["code"] == "UNSUPPORTED_FILE_TYPE"
        assert enqueued == []


async def test_complete_too_large(api, team, enqueued, monkeypatch):
    doc_id = (await api.post("/v1/documents/upload-url", headers=team.h("owner"), json=new_doc())).json()["document_id"]

    async def huge(bucket: str, path: str) -> dict[str, object]:
        return {"size": MAX_BYTES + 1, "content_type": "application/pdf"}

    monkeypatch.setattr(storage, "info", huge)
    r = await api.post(f"/v1/documents/{doc_id}/complete", headers=team.h("owner", **idem()))
    assert r.status_code == 413 and r.json()["error"]["code"] == "FILE_TOO_LARGE"
    assert r.json()["error"]["details"] == {"max_bytes": MAX_BYTES}
    assert enqueued == []


async def test_upload_rate_limit(api, team):
    counter = f"rl:upload:{team.users['owner']}"
    await redis().set(counter, 59, ex=60)  # 59 of this minute's 60 uploads used
    try:
        last = await api.post("/v1/documents/upload-url", headers=team.h("owner"), json=new_doc())
        over = await api.post("/v1/documents/upload-url", headers=team.h("owner"), json=new_doc())
    finally:
        await redis().delete(counter)
    assert last.status_code == 201
    assert over.status_code == 429 and over.json()["error"]["code"] == "RATE_LIMITED"


async def test_complete_without_upload(api, team, enqueued):
    doc_id = (await api.post("/v1/documents/upload-url", headers=team.h("owner"), json=new_doc())).json()["document_id"]
    r = await api.post(f"/v1/documents/{doc_id}/complete", headers=team.h("owner", **idem()))
    assert r.status_code == 409 and r.json()["error"]["code"] == "UPLOAD_MISSING"
    assert enqueued == []


async def test_other_org_and_deleted_are_404(api, team, other, matter_id):
    doc_id = (await api.post("/v1/documents/upload-url", headers=team.h("owner"), json=new_doc())).json()["document_id"]
    await sql("update public.documents set upload_status = 'ready' where id = :id", id=doc_id)
    outsider = other.h("other")
    assert (await api.get(f"/v1/documents/{doc_id}/download-url", headers=outsider)).status_code == 404
    r = await api.post(f"/v1/documents/{doc_id}/complete", headers=outsider | idem())
    assert r.status_code == 404
    r = await api.post("/v1/documents/upload-url", headers=outsider, json=new_doc(matter_id=matter_id))
    assert r.status_code == 404  # another organisation's matter

    await sql("update public.documents set deleted_at = now() where id = :id", id=doc_id)
    assert (await api.get(f"/v1/documents/{doc_id}/download-url", headers=team.h("owner"))).status_code == 404


@pytest.mark.parametrize(
    "fields",
    [{"mime": "text/html"}, {"size_bytes": 0}, {"size_bytes": 52428801}, {"title": ""}, {"kind": "contract"}],
)
async def test_upload_validation(api, team, fields):
    r = await api.post("/v1/documents/upload-url", headers=team.h("owner"), json=new_doc(**fields))
    assert r.status_code == 422


@pytest.fixture
async def court_order_id():
    """A shared court order with no stored copy. Removed afterwards with the PDF fetched for it, so no global row or
    object outlives the test (orders keep their row: court_order_id is set null)."""
    [co] = await sql(
        "insert into public.court_orders (cnr, provider_ref) values (:c, 'order-1.pdf') "
        "on conflict (cnr, provider_ref) do update set storage_path = null, sha256 = null returning id::text",
        c=CNR,
    )  # a crashed earlier run may have left the row
    yield co["id"]
    [row] = await sql("delete from public.court_orders where id = :id returning storage_path", id=co["id"])
    if row["storage_path"]:
        r = await storage._call("DELETE", "/object/court-orders", json={"prefixes": [row["storage_path"]]})
        r.raise_for_status()


async def test_order_pdf_fetched_once(api, team, other, matter_id, court_order_id, monkeypatch, enqueued):
    [order] = await sql(
        "insert into public.orders (org_id, matter_id, court_order_id, title) values (:o, :m, :co, 'Order') "
        "returning id::text",
        o=team.org_id, m=matter_id, co=court_order_id,
    )  # fmt: skip
    url = f"/v1/orders/{order['id']}/pdf-url"
    calls = "select count(*) as n from public.provider_calls where org_id = :o and operation = 'order_pdf'"

    lock = f"order-pdf:{court_order_id}"
    await redis().set(lock, "1", ex=60)
    try:
        r = await api.get(url, headers=team.h("junior"))
    finally:
        await redis().delete(lock)
    assert r.status_code == 409 and r.json()["error"] == {
        "code": "ORDER_PDF_FETCHING",
        "message": "This order is being fetched",
        "retryable": True,
        "details": {},
    }

    r = await api.get(url, headers=team.h("junior"))
    assert r.status_code == 200, r.text
    assert r.json()["expires_in_s"] == 300
    assert await redis().get(lock) is None  # released after the fetch
    async with httpx.AsyncClient() as http:
        file = await http.get(r.json()["url"])
    assert file.status_code == 200 and file.content.startswith(b"%PDF")
    assert (await sql(calls, o=team.org_id)) == [{"n": 1}]
    [stored] = await sql("select storage_path, sha256 from public.court_orders where id = :id", id=court_order_id)
    assert stored["storage_path"] == f"{CNR}/{stored['sha256']}.pdf"
    assert enqueued == [(EXTRACT_TEXT, "court_order", court_order_id)]  # then its text is read

    r = await api.get(url, headers=team.h("owner"))
    assert r.status_code == 200
    assert (await sql(calls, o=team.org_id)) == [{"n": 1}]  # served from the shared copy

    assert (await api.get(url, headers=other.h("other"))).status_code == 404

    # A fetch that outlives its lock leaves the next holder's lock alone (and re-storing the same PDF is fine).
    await sql("update public.court_orders set storage_path = null where id = :id", id=court_order_id)
    real_put = storage.put

    async def put_after_lock_expired(bucket: str, path: str, data: bytes, content_type: str) -> None:
        await redis().set(lock, "next-holder", ex=60)
        await real_put(bucket, path, data, content_type)

    monkeypatch.setattr(storage, "put", put_after_lock_expired)
    try:
        assert (await api.get(url, headers=team.h("owner"))).status_code == 200
        assert await redis().get(lock) == b"next-holder"
    finally:
        await redis().delete(lock)


async def test_order_without_court_copy(api, team, matter_id):
    [order] = await sql(
        "insert into public.orders (org_id, matter_id, title) values (:o, :m, 'Typed order') returning id::text",
        o=team.org_id, m=matter_id,
    )  # fmt: skip
    r = await api.get(f"/v1/orders/{order['id']}/pdf-url", headers=team.h("owner"))
    assert r.status_code == 404 and r.json()["error"]["code"] == "ORDER_PDF_UNAVAILABLE"
    r = await api.get(f"/v1/orders/{uuid.uuid4()}/pdf-url", headers=team.h("owner"))
    assert r.status_code == 404 and r.json()["error"]["code"] == "NOT_FOUND"
