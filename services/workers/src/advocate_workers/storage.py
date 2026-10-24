"""Supabase Storage for workers, with the service key (spec §15.5): order PDFs in `court-orders`
({cnr}/{sha256}.pdf, shared by every organisation) and uploaded files in `documents`. Each call opens its own HTTP
client, since every task runs its own event loop. Raises httpx.HTTPError when Storage is unavailable."""

import httpx

from advocate_shared.settings import get_settings


def _client() -> httpx.AsyncClient:
    s = get_settings()
    key = s.supabase_service_role_key
    return httpx.AsyncClient(
        base_url=f"{s.supabase_server_url}/storage/v1",
        headers={"Authorization": f"Bearer {key}", "apikey": key},
        timeout=60,
    )


async def get(bucket: str, path: str) -> bytes | None:
    """The object's bytes, or None if it isn't there. Uploads are at most 50 MB (§4.3), so they fit in memory. Storage
    answers most errors with 400 (a wrong service key reads as a missing bucket), so only a missing key is None."""
    async with _client() as c:
        r = await c.get(f"/object/{bucket}/{path}")
    if missing(r):
        return None
    r.raise_for_status()
    return r.content


def missing(r: httpx.Response) -> bool:
    """A missing object is 400 with code NoSuchKey; a bad key reads as NoSuchBucket or AccessDenied (a fault)."""
    if r.status_code == 404:
        return True
    try:
        return r.status_code == 400 and r.json().get("code") == "NoSuchKey"
    except ValueError:  # a proxy's HTML error page
        return False


async def put(bucket: str, path: str, data: bytes, content_type: str) -> None:
    """Store an object. An existing object at a content-addressed path holds the same bytes, so that is success."""
    async with _client() as c:
        r = await c.post(f"/object/{bucket}/{path}", content=data, headers={"Content-Type": content_type})
    if r.status_code == 409 or (r.status_code == 400 and r.json().get("statusCode") == "409"):
        return
    r.raise_for_status()
