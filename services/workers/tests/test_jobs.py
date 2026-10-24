"""Job lifecycle: claim, finish, fail, cancel, the run lock, Celery retries, the stale-job sweeper, scheduled locks."""

import asyncio
from datetime import UTC, datetime
from types import SimpleNamespace
from typing import Any, cast

import pytest
from celery import Task
from conftest import Factory, sql, unavailable

from advocate_shared import tasks
from advocate_workers import jobs
from advocate_workers.courts import Paused
from court_data.models import CaseNotFound


async def job_row(job_id: str) -> dict[str, Any]:
    [row] = await sql("select status, progress, result, error from public.jobs where id = :id", id=job_id)
    return row


async def test_job_runs_once_and_finishes(make: Factory):
    org = await make.org()
    job_id = await make.job(org, "fetch_cases", {"matter_ids": ["m1"]})
    seen: list[jobs.Job] = []

    async def body(job: jobs.Job, _) -> dict:
        seen.append(job)
        assert (await job_row(job.id))["status"] == "running"
        assert await jobs.set_progress(job.id, {"done": 1, "total": 1})
        return {"fetched": 1}

    await jobs.run(job_id, body)
    assert [(j.kind, j.input, j.org_id) for j in seen] == [("fetch_cases", {"matter_ids": ["m1"]}, org.id)]
    assert await job_row(job_id) == {
        "status": "done",
        "progress": {"done": 1, "total": 1},
        "result": {"fetched": 1},
        "error": None,
    }
    await jobs.run(job_id, body)  # redelivered after it finished: not run again
    assert len(seen) == 1


async def test_cancel_wins_over_the_worker(make: Factory):
    org = await make.org()
    job_id = await make.job(org, "find_cases", {})

    async def body(job: jobs.Job, _) -> dict:
        await jobs.set_progress(job.id, {"found": 2})
        await sql("update public.jobs set status = 'cancelled' where id = :id", id=job.id)  # POST /v1/jobs/{id}/cancel
        assert await jobs.is_cancelled(job.id)
        assert not await jobs.set_progress(job.id, {"found": 3})
        return {"found": 3}

    await jobs.run(job_id, body)
    assert await job_row(job_id) == {"status": "cancelled", "progress": {"found": 2}, "result": None, "error": None}

    called = []
    await jobs.run(job_id, lambda job, r: called.append(job))  # type: ignore[arg-type, return-value]
    assert called == []  # a cancelled job is never claimed again


@pytest.mark.parametrize(
    ("error", "code"),
    [
        (jobs.JobFailed("COURT_PROVIDER_UNAVAILABLE", {"found": 1}), "COURT_PROVIDER_UNAVAILABLE"),
        (Paused("COURT_DATA_BUDGET_REACHED"), "COURT_DATA_BUDGET_REACHED"),
        (CaseNotFound("TEST000000000000"), "CASE_NOT_FOUND"),
    ],
)
async def test_job_failures_keep_the_code(make: Factory, error: Exception, code: str):
    org = await make.org()
    job_id = await make.job(org, "refresh_case", {"matter_id": "x"})

    async def body(job: jobs.Job, _) -> dict:
        raise error

    await jobs.run(job_id, body)
    row = await job_row(job_id)
    assert (row["status"], row["error"]) == ("failed", code)
    assert row["result"] == (error.result if isinstance(error, jobs.JobFailed) else None)


async def test_a_removed_members_job_fails_without_running(make: Factory):
    org = await make.org(members={"Rakesh Jain": "advocate"})
    rakesh = org.users["Rakesh Jain"]
    job_id = await make.job(org, "find_cases", {}, user=rakesh)
    await sql("update public.memberships set status = 'removed' where org_id = :o and user_id = :u", o=org.id, u=rakesh)
    called = []
    await jobs.run(job_id, lambda job, r: called.append(job))  # type: ignore[arg-type, return-value]
    assert called == []  # no searches costed to the organisation, nothing written into it
    row = await job_row(job_id)
    assert (row["status"], row["error"]) == ("failed", "NOT_A_MEMBER")


async def test_unexpected_errors_fail_the_job_and_propagate(make: Factory):
    org = await make.org()
    job_id = await make.job(org, "refresh_case", {})

    async def body(job: jobs.Job, _) -> dict:
        raise KeyError("bug")

    with pytest.raises(KeyError):
        await jobs.run(job_id, body)
    assert (await job_row(job_id))["error"] == "INTERNAL_ERROR"


async def test_provider_outage_retries_and_resumes(make: Factory, r):
    org = await make.org()
    job_id = await make.job(org, "fetch_cases", {})
    runs: list[dict] = []

    async def body(job: jobs.Job, _) -> dict:
        runs.append(job.progress)
        if not job.progress:
            await jobs.set_progress(job.id, {"done": ["m1"]})
            raise unavailable()
        return {"done": len(job.progress["done"])}

    with pytest.raises(jobs.RetryLater) as raised:
        await jobs.run(job_id, body)
    assert raised.value.code == "COURT_PROVIDER_UNAVAILABLE"
    assert (await job_row(job_id))["status"] == "running"
    assert await r.get(f"job-lock:{job_id}") is None  # the retry can take the lock
    await jobs.run(job_id, body)
    assert runs == [{}, {"done": ["m1"]}]
    assert (await job_row(job_id))["result"] == {"done": 1}


async def test_a_running_job_is_not_run_twice(make: Factory, r):
    org = await make.org()
    job_id = await make.job(org, "find_cases", {})
    await r.set(f"job-lock:{job_id}", "other-worker", ex=60)
    try:
        called = []
        await jobs.run(job_id, lambda job, r: called.append(job))  # type: ignore[arg-type, return-value]
        assert called == []
        assert (await job_row(job_id))["status"] == "queued"
    finally:
        await r.delete(f"job-lock:{job_id}")


class StubTask:
    max_retries = 2

    def __init__(self, retries: int):
        self.request = SimpleNamespace(retries=retries)
        self.countdowns: list[int] = []

    def retry(self, countdown: int) -> Exception:
        self.countdowns.append(countdown)
        return RuntimeError("retry scheduled")


async def test_run_job_backs_off_then_fails(make: Factory):
    org = await make.org()
    job_id = await make.job(org, "scan_document", {})

    async def body(job: jobs.Job, _) -> dict:
        raise jobs.RetryLater("SCANNER_UNAVAILABLE")

    first = StubTask(retries=1)
    with pytest.raises(RuntimeError, match="retry scheduled"):
        await asyncio.to_thread(jobs.run_job, cast(Task, first), job_id, body)  # Celery runs it in its own loop
    assert first.countdowns == [60]
    assert (await job_row(job_id))["status"] == "running"

    last = StubTask(retries=2)
    await asyncio.to_thread(jobs.run_job, cast(Task, last), job_id, body)
    assert last.countdowns == []
    assert (await job_row(job_id))["error"] == "SCANNER_UNAVAILABLE"


async def test_sweeper_requeues_lost_jobs_and_expires_old_ones(make: Factory, sent):
    org = await make.org()
    ids = {}
    for name, kind, status, age in [
        ("lost_queued", "scan_document", "queued", 11),
        ("lost_running", "fetch_cases", "running", 31),
        ("busy", "fetch_cases", "running", 5),
        ("waiting", "find_cases", "queued", 2),
        ("cancelled", "find_cases", "cancelled", 40),
        ("unknown_kind", "probe", "queued", 40),
    ]:
        ids[name] = await make.job(org, kind, {}, status=status, age_min=age)
    ids["ancient"] = await make.job(org, "find_cases", {}, status="running")
    await sql("update public.jobs set created_at = now() - interval '7 hours' where id = :id", id=ids["ancient"])

    counts = await jobs.sweep(datetime.now(UTC))
    mine = [(name, args[0]) for name, args in sent if args[0] in ids.values()]
    assert sorted(mine) == sorted([(tasks.SCAN_DOCUMENT, ids["lost_queued"]), (tasks.FETCH_CASES, ids["lost_running"])])
    assert counts["requeued"] >= 2 and counts["expired"] >= 1
    assert (await job_row(ids["ancient"]))["error"] == "JOB_EXPIRED"
    assert (await job_row(ids["cancelled"]))["status"] == "cancelled"

    sent.clear()
    await jobs.sweep(datetime.now(UTC))  # just touched: not re-enqueued every run
    assert [a for _, a in sent if a[0] in ids.values()] == []


async def test_scheduled_runs_once_and_frees_the_key_on_failure(r):
    key = f"sched:test:{datetime.now(UTC).timestamp()}"
    try:
        async with jobs.scheduled(r, key) as first:
            assert first
        async with jobs.scheduled(r, key) as again:
            assert not again
        await r.delete(key)
        with pytest.raises(RuntimeError):
            async with jobs.scheduled(r, key) as first:
                assert first
                raise RuntimeError("provider down")
        assert await r.get(key) is None
    finally:
        await r.delete(key)
