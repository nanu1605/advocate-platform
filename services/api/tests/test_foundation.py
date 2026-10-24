"""Shared API plumbing: idempotency, after-commit job enqueueing, SQL rule errors, rate limits, court-data costs."""

import uuid

import pytest
from fastapi import Request
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text

from advocate_api.courts import court_data
from advocate_api.db import CurrentOrg, UserDb
from advocate_api.errors import ApiError
from advocate_api.idempotency import IdempotencyKey
from advocate_api.jobs import create_job
from advocate_api.main import create_app
from advocate_api.ratelimit import limit
from court_data.models import Capability

from .conftest import make_team, sql

PHONES = {"owner": ("919999900003", "owner")}  # shares test_api's number; runs after it in one session


@pytest.fixture(scope="module")
async def probe():
    """An app with probe routes over the shared plumbing; `runs` counts real executions."""
    app = create_app()
    runs: list[str] = []

    @app.post("/probe/job", status_code=202)
    async def job(idem: IdempotencyKey, db: UserDb, org: CurrentOrg, request: Request) -> dict:
        runs.append("job")
        job_id = await create_job(db, request, task="probe.task", kind="probe", org_id=org.org_id, job_input={"n": 1})
        return idem.keep({"job_id": str(job_id)})

    @app.post("/probe/fail")
    async def fail(idem: IdempotencyKey, db: UserDb, request: Request) -> dict:
        runs.append("fail")
        await create_job(db, request, task="probe.task", kind="probe", org_id=None, job_input={})
        raise ApiError(409, "NOPE", "always fails")

    @app.post("/probe/limit")
    async def limited(db: UserDb) -> dict:
        await limit(f"probe:{uuid.uuid4()}", 0, 60)
        return {}

    @app.post("/probe/allowance")
    async def allowance(db: UserDb, org: CurrentOrg) -> dict:
        await db.execute(
            text("insert into public.matters (org_id, source, tracking, cnr) values (:o, 'cnr', 'auto', :c)"),
            {"o": org.org_id, "c": f"TESTFND{uuid.uuid4().hex[:9].upper()}"},
        )
        return {}

    @app.post("/probe/search")
    async def search(db: UserDb, org: CurrentOrg) -> dict:
        async with court_data(org.org_id) as router:
            case = await router.run(
                Capability.CASE_DETAIL, lambda p: p.get_case("TEST010000012024"), org_id=str(org.org_id)
            )
        return {"title": case.title}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c, runs


@pytest.fixture(scope="module")
async def team():
    return await make_team(PHONES)


async def test_idempotent_replay_and_after_commit_enqueue(probe, team, enqueued):
    c, runs = probe
    runs.clear()
    h = team.h("owner", **{"Idempotency-Key": f"key-{uuid.uuid4()}"})
    first = await c.post("/probe/job", headers=h)
    assert first.status_code == 202
    again = await c.post("/probe/job", headers=h)
    assert again.status_code == 202 and again.json() == first.json()
    assert again.headers["Idempotent-Replay"] == "true"
    assert runs == ["job"]
    job_id = first.json()["job_id"]
    assert enqueued == [("probe.task", job_id)]
    [job] = await sql("select kind, input, user_id::text, status from public.jobs where id = :id", id=job_id)
    assert job == {"kind": "probe", "input": {"n": 1}, "user_id": team.users["owner"], "status": "queued"}

    missing = await c.post("/probe/job", headers=team.h("owner"))
    assert missing.status_code == 422  # the header is required


async def test_failed_request_rolls_back_and_can_retry(probe, team, enqueued):
    c, runs = probe
    runs.clear()
    h = team.h("owner", **{"Idempotency-Key": f"key-{uuid.uuid4()}"})
    assert (await c.post("/probe/fail", headers=h)).json()["error"]["code"] == "NOPE"
    assert (await c.post("/probe/fail", headers=h)).json()["error"]["code"] == "NOPE"
    assert runs == ["fail", "fail"]  # not replayed: errors aren't stored
    assert enqueued == []  # rolled back, so nothing was enqueued


async def test_rate_limit_error(probe, team):
    c, _ = probe
    r = await c.post("/probe/limit", headers=team.h("owner"))
    assert r.status_code == 429
    assert r.json()["error"]["code"] == "RATE_LIMITED"
    assert r.json()["error"]["details"]["retry_after_s"] >= 1


async def test_tracked_case_limit_maps_to_409(probe, team):
    c, _ = probe
    await sql("update public.app_config set value = '0' where key = 'beta_tracked_case_allowance'")
    try:
        r = await c.post("/probe/allowance", headers=team.h("owner"))
    finally:
        await sql("update public.app_config set value = '100' where key = 'beta_tracked_case_allowance'")
    assert r.status_code == 409
    assert r.json()["error"] == {
        "code": "TRACKED_CASE_LIMIT",
        "message": "Your plan tracks no more cases",
        "retryable": False,
        "details": {"limit": 0},
    }


async def test_court_data_calls_are_costed(probe, team):
    c, _ = probe
    r = await c.post("/probe/search", headers=team.h("owner"))
    assert r.status_code == 200, r.text
    assert r.json()["title"]
    rows = await sql(
        "select operation, status, cost_inr from public.provider_calls where org_id = :o "
        "order by created_at desc limit 1",
        o=team.org_id,
    )
    assert rows == [{"operation": "case_detail", "status": "ok", "cost_inr": pytest.approx(1.5)}]
    [ledger] = await sql("select kind, cost_inr from public.usage_ledger where org_id = :o", o=team.org_id)
    assert ledger["kind"] == "provider_call"
