"""Job lifecycle (spec §6.2, ADR 0011): a `jobs` row the user's devices sync for progress, plus a Celery task whose only
argument is the job id. Tasks can be lost (Redis restart) or redelivered (acks_late), so every job body is idempotent
and resumes from `jobs.input` / `jobs.progress`; a Redis lock keeps two runs of one job apart, and the sweeper
re-enqueues lost jobs. Status changes only ever move a `running` job, so a cancel (API) is never overwritten."""

import asyncio
import json
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import uuid4

from celery import Task
from redis.asyncio import Redis
from sqlalchemy import text

from advocate_shared import tasks
from advocate_shared.ist import now_ist
from advocate_workers import db
from advocate_workers.celery_app import SWEEP_JOBS, app
from court_data.models import ProviderError

# ponytail: a run longer than the lock (15 min) could overlap a redelivery; jobs are far shorter, extend if they grow.
LOCK_TTL_S = 900
SCHED_TTL_S = 26 * 3600
RELEASE = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end return 0"
KIND_TASKS = {
    "find_cases": tasks.FIND_CASES,
    "fetch_cases": tasks.FETCH_CASES,
    "refresh_case": tasks.REFRESH_CASE,
    "scan_document": tasks.SCAN_DOCUMENT,
}


@dataclass(frozen=True, slots=True)
class Job:
    id: str
    org_id: str | None
    user_id: str
    kind: str
    input: dict[str, Any]
    progress: dict[str, Any]  # what an earlier run of this job got through, for resuming
    result: dict[str, Any] | None


class JobFailed(Exception):
    """Raised by a job body: the job fails with `code` (an API error code the app shows), keeping what it wrote."""

    def __init__(self, code: str, result: dict[str, Any] | None = None):
        super().__init__(code)
        self.code, self.result = code, result


class RetryLater(Exception):
    """Raised by a job body for a passing failure: Celery retries the task with backoff and the job resumes; after
    the last retry it fails with `code`. A retryable ProviderError is turned into RetryLater by `run`."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


type Body = Callable[[Job, Redis], Awaitable[dict[str, Any] | None]]


def send(name: str, *args: str) -> None:
    """The one place workers enqueue Celery tasks, called only after the transaction that made the work visible has
    committed. Tests replace it; call it as `jobs.send(...)` so they can."""
    app.send_task(name, args=list(args))


def _json(value: Any) -> str:
    return json.dumps(value, default=str)


CLAIM = """
update public.jobs j set status = 'running'
where j.id = :id and j.status in ('queued', 'running')
  and (j.org_id is null or exists (select 1 from public.memberships ms
                                   where ms.org_id = j.org_id and ms.user_id = j.user_id and ms.status = 'active'))
returning j.id::text, j.org_id::text, j.user_id::text, j.kind, j.input, j.progress, j.result
"""
NOT_A_MEMBER = """
update public.jobs set status = 'failed', error = 'NOT_A_MEMBER' where id = :id and status in ('queued', 'running')
"""


async def claim(job_id: str) -> Job | None:
    """Mark the job running and return it; None once it is cancelled, finished or gone. A running job is claimed
    again on redelivery (the run lock keeps runs apart) so it can resume. A job whose user is no longer an active
    member of its organisation fails with NOT_A_MEMBER instead: it would spend the organisation's money and write
    into its data."""
    async with db.engine().begin() as c:
        found = await db.rows(c, CLAIM, id=job_id)
        if not found:
            await c.execute(text(NOT_A_MEMBER), {"id": job_id})
    return Job(**found[0]) if found else None


async def _update(job_id: str, assignments: str, **params: Any) -> bool:
    async with db.engine().begin() as c:
        result = await c.execute(
            text(f"update public.jobs set {assignments} where id = :id and status = 'running'"),  # noqa: S608
            {"id": job_id, **params},
        )
    return result.rowcount == 1  # type: ignore[attr-defined]


async def set_progress(job_id: str, progress: dict[str, Any]) -> bool:
    """Replace `jobs.progress`. False once the job is no longer running (cancelled or expired): stop then."""
    return await _update(job_id, "progress = cast(:p as jsonb)", p=_json(progress))


async def finish(job_id: str, result: dict[str, Any]) -> bool:
    return await _update(job_id, "status = 'done', result = cast(:r as jsonb), error = null", r=_json(result))


async def fail(job_id: str, code: str, result: dict[str, Any] | None = None) -> bool:
    kept = None if result is None else _json(result)
    return await _update(
        job_id, "status = 'failed', error = :e, result = coalesce(cast(:r as jsonb), result)", e=code, r=kept
    )


async def is_cancelled(job_id: str) -> bool:
    """True once the job is no longer running: cancelled by its user (results so far are kept) or expired."""
    async with db.engine().connect() as c:
        status = (await c.execute(text("select status from public.jobs where id = :id"), {"id": job_id})).scalar()
    return status != "running"


async def run(job_id: str, body: Body) -> None:
    """Run one job: take its lock, claim it, run `body`, then finish it with the returned result. JobFailed (and
    courts.Paused) fail the job with their code; a non-retryable ProviderError fails it with the provider's code;
    RetryLater propagates (see run_job); anything else fails it with INTERNAL_ERROR and propagates."""
    r = db.redis()
    lock, token = f"job-lock:{job_id}", uuid4().hex
    try:
        if not await r.set(lock, token, nx=True, ex=LOCK_TTL_S):
            return  # another run of this job is in progress
        try:
            job = await claim(job_id)
            if job is None:
                return
            try:
                result = await body(job, r)
            except JobFailed as e:
                await fail(job_id, e.code, e.result)
                return
            except ProviderError as e:
                if e.retryable:
                    raise RetryLater("COURT_PROVIDER_UNAVAILABLE") from e
                await fail(job_id, e.code)
                return
            except RetryLater:
                raise
            except Exception:
                await fail(job_id, "INTERNAL_ERROR")
                raise
            await finish(job_id, result or {})
        finally:
            await r.register_script(RELEASE)(keys=[lock], args=[token])
    finally:
        await r.aclose()


def run_job(task: Task, job_id: str, body: Body) -> None:
    """Celery glue for a job task declared with bind=True and max_retries: RetryLater retries after 30 s, 60 s, …
    (at most 10 min); after the last retry the job fails with the RetryLater code."""
    try:
        asyncio.run(run(job_id, body))
    except RetryLater as e:
        retries = task.request.retries
        if retries >= (task.max_retries or 0):
            asyncio.run(fail(job_id, e.code))
            return
        raise task.retry(countdown=min(30 * 2**retries, 600)) from e


def run_task[T](fn: Callable[[Redis], Awaitable[T]]) -> T:
    """Celery glue for a scheduled or internal task: one event loop and one Redis client per run."""

    async def main() -> T:
        r = db.redis()
        try:
            return await fn(r)
        finally:
            await r.aclose()

    return asyncio.run(main())


@asynccontextmanager
async def scheduled(r: Redis, key: str) -> AsyncIterator[bool]:
    """Yields True for the first run under `key` (sched:{name}:{date}[:{attempt}]): a beat tick that fires twice, or a
    redelivery after success, runs once. A run that raises frees the key so a retry can run.
    ponytail: a worker killed mid-run keeps the key for 26 h; the next attempt or day picks the work up."""
    first = bool(await r.set(key, "1", nx=True, ex=SCHED_TTL_S))
    try:
        yield first
    except BaseException:
        if first:
            await r.delete(key)
        raise


EXPIRE = """
update public.jobs set status = 'failed', error = 'JOB_EXPIRED'
where status in ('queued', 'running') and created_at < cast(:now as timestamptz) - interval '6 hours'
"""
STALE = """
update public.jobs set updated_at = now()
where kind = any(:kinds) and (
  (status = 'queued' and updated_at < cast(:now as timestamptz) - interval '10 minutes')
  or (status = 'running' and updated_at < cast(:now as timestamptz) - interval '30 minutes'))
returning id::text, kind
"""


async def sweep(now: datetime) -> dict[str, int]:
    """Fail jobs older than 6 h (JOB_EXPIRED); re-enqueue queued jobs untouched for 10 min and running ones untouched
    for 30 min (lost in Redis, or their worker died). Touching them spaces out the next re-enqueue."""
    async with db.engine().begin() as c:
        expired = (await c.execute(text(EXPIRE), {"now": now})).rowcount  # type: ignore[attr-defined]
        stale = await db.rows(c, STALE, now=now, kinds=list(KIND_TASKS))
    for job in stale:
        send(KIND_TASKS[job["kind"]], job["id"])
    return {"expired": expired, "requeued": len(stale)}


@app.task(name=SWEEP_JOBS)
def sweep_jobs() -> dict[str, int]:
    return asyncio.run(sweep(now_ist()))
