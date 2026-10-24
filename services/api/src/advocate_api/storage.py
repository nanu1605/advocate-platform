"""Supabase Storage with the service key, used only after the API has checked access as the user (spec §15.5).
Buckets are private; download URLs live 5 minutes. Upload tokens are Supabase's fixed 2 hours, but each is bound
to one new path and can't overwrite or read (ADR 0011)."""

from functools import lru_cache
from typing import Any
from urllib.parse import quote

import httpx

from advocate_api.errors import ApiError
from advocate_shared.settings import get_settings

DOWNLOAD_TTL_S = 300


@lru_cache
def _client() -> httpx.AsyncClient:
    s = get_settings()
    key = s.supabase_service_role_key
    return httpx.AsyncClient(
        base_url=f"{s.supabase_server_url}/storage/v1",
        headers={"Authorization": f"Bearer {key}", "apikey": key},
        timeout=30,
    )


def _public(path: str) -> str:
    """Storage returns paths relative to /storage/v1; the app needs a URL it can reach."""
    return f"{get_settings().supabase_url}/storage/v1{path}"


async def _call(method: str, path: str, **kwargs: Any) -> httpx.Response:
    try:
        r = await _client().request(method, path, **kwargs)
    except httpx.TransportError as e:
        raise ApiError(503, "STORAGE_UNAVAILABLE", "File storage is unavailable", retryable=True) from e
    if r.status_code >= 500:
        raise ApiError(503, "STORAGE_UNAVAILABLE", "File storage is unavailable", retryable=True)
    return r


async def upload_url(bucket: str, path: str) -> str:
    r = await _call("POST", f"/object/upload/sign/{bucket}/{path}")
    r.raise_for_status()
    return _public(r.json()["url"])


async def download_url(bucket: str, path: str, filename: str | None = None) -> str:
    body: dict[str, Any] = {"expiresIn": DOWNLOAD_TTL_S}
    r = await _call("POST", f"/object/sign/{bucket}/{path}", json=body)
    if r.status_code in (400, 404):
        raise ApiError(404, "FILE_NOT_FOUND", "File not found")
    r.raise_for_status()
    url = _public(r.json()["signedURL"])
    return f"{url}&download={quote(filename)}" if filename else url


async def info(bucket: str, path: str) -> dict[str, Any] | None:
    """Size and content type of a stored object, or None if it isn't there."""
    r = await _call("GET", f"/object/info/{bucket}/{path}")
    if r.status_code in (400, 404):
        return None
    r.raise_for_status()
    return r.json()


async def put(bucket: str, path: str, data: bytes, content_type: str) -> None:
    r = await _call("POST", f"/object/{bucket}/{path}", content=data, headers={"Content-Type": content_type})
    # Already stored (Storage answers 400 with statusCode "409"): content-addressed paths hold the same bytes.
    if r.status_code == 409 or (r.status_code == 400 and r.json().get("statusCode") == "409"):
        return
    r.raise_for_status()
