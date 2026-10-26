"""Storage round trip, database error hygiene and the Celery app wiring."""

import hashlib
import importlib

import httpx
import pytest
from conftest import _up, random_cnr, requires_stack
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from advocate_shared import tasks
from advocate_shared.settings import get_settings
from advocate_workers import celery_app, db, storage


async def test_storage_put_get_is_idempotent():
    if not _up(55321):
        pytest.skip("local Supabase not running (just dev)")
    pdf = b"%PDF-1.4 worker storage test"
    path = f"{random_cnr()}/{hashlib.sha256(pdf).hexdigest()}.pdf"
    try:
        await storage.put("court-orders", path, pdf, "application/pdf")
        await storage.put("court-orders", path, pdf, "application/pdf")  # content-addressed: already there is fine
        assert await storage.get("court-orders", path) == pdf
        assert await storage.get("court-orders", f"{path}.missing") is None
    finally:
        s = get_settings()
        key = s.supabase_service_role_key
        async with httpx.AsyncClient(headers={"Authorization": f"Bearer {key}", "apikey": key}) as c:
            await c.request(
                "DELETE", f"{s.supabase_server_url}/storage/v1/object/court-orders", json={"prefixes": [path]}
            )


async def test_storage_errors_other_than_a_missing_object_raise(monkeypatch: pytest.MonkeyPatch):
    if not _up(55321):
        pytest.skip("local Supabase not running (just dev)")
    monkeypatch.setattr(get_settings(), "supabase_service_role_key", "a-rotated-key")  # Storage: 400, bucket not found
    with pytest.raises(httpx.HTTPStatusError):
        await storage.get("documents", "nope/missing")


def test_only_a_missing_key_counts_as_missing():
    assert storage.missing(httpx.Response(404))
    assert storage.missing(httpx.Response(400, json={"statusCode": "404", "code": "NoSuchKey"}))
    assert not storage.missing(httpx.Response(400, json={"statusCode": "404", "code": "NoSuchBucket"}))
    assert not storage.missing(httpx.Response(400, text="<html>Bad gateway</html>"))


async def test_database_errors_carry_no_parameters():
    requires_stack()
    with pytest.raises(DBAPIError) as raised:
        async with db.engine().connect() as c:
            await c.execute(text("select 1 / 0, cast(:title as text)"), {"title": "Ramesh Kumar v. State of MP"})
    assert "Ramesh" not in str(raised.value)  # the error is logged (Sentry later): never case content (§7.2)


def test_the_beat_schedule_runs_on_its_own_queue():
    routes = celery_app.app.conf.task_routes
    for name in (celery_app.CAUSE_LIST_TOMORROW, celery_app.POST_HEARING_REFRESH, celery_app.TODAY_MORNING):
        assert routes[name] == {"queue": "scheduled"}
    assert tasks.SCAN_DOCUMENT not in routes and tasks.FIND_CASES not in routes  # user jobs: the default queue
    assert routes[tasks.EXTRACT_TEXT] == {"queue": "text"}  # a long scan's OCR holds up neither


def test_every_module_is_included_and_every_beat_task_is_named():
    names = {
        v
        for k, v in vars(celery_app).items()
        if k.isupper() and isinstance(v, str) and v.startswith("advocate_workers.")
    }
    names |= {tasks.FIND_CASES, tasks.FETCH_CASES, tasks.REFRESH_CASE, tasks.SCAN_DOCUMENT, tasks.EXTRACT_TEXT}
    beat = {entry["task"] for entry in celery_app.app.conf.beat_schedule.values()}
    assert beat <= names
    for module in celery_app.app.conf.include:
        importlib.import_module(module)
    registered = {n for n in celery_app.app.tasks if n.startswith("advocate_workers.")}
    assert registered <= names  # feature modules register only the names fixed in celery_app
