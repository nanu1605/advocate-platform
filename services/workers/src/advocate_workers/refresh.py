"""Case refreshes (spec §11.5, §11.6, §11.8): the FETCH_CASES and REFRESH_CASE jobs, post_hearing_refresh (19:30),
post_hearing_retry (08:00 and 19:30 the next day) and weekly_sweep (Sunday 10:00).

Every fetch ends the same way: apply_case and fan_out in one transaction, then ORDER_PIPELINE for each new order once
that has committed. The jobs are costed to the organisation that asked; the scheduled refreshes are shared fetches
(platform rows). Budgets (§11.8): the first post-hearing refresh is never paused; retry 1 and the weekly sweep pause
at the global daily cap; retry 2 also skips CNRs whose tracking organisations are all over budget."""

import asyncio
from collections.abc import Awaitable, Callable
from datetime import date, datetime, timedelta
from typing import Any

import structlog
from celery import Task
from redis.asyncio import Redis

from advocate_shared import tasks
from advocate_shared.ist import now_ist
from advocate_workers import db, jobs
from advocate_workers.celery_app import ORDER_PIPELINE, POST_HEARING_REFRESH, POST_HEARING_RETRY, WEEKLY_SWEEP, app
from advocate_workers.courts import CourtData, Paused, Spend
from advocate_workers.diff import Event, apply_case
from advocate_workers.fanout import fan_out
from court_data.models import Capability, CaseNotFound, CaseRecord, CourtDataProvider, ProviderError, RefreshTicket

log = structlog.get_logger()

CHUNK = 50  # bulk_refresh takes at most 50 CNRs (eCourtsIndia)
MAX_WAIT_S = 60  # longest wait for a refresh ticket (eCourtsIndia: 5-10 s single, ~30 s bulk)
FETCH_CACHE = timedelta(hours=6)  # fetch_cases reuses a court record this fresh
REFRESH_CACHE = timedelta(minutes=15)  # on-demand refresh reuses a court record this fresh
# ponytail: eCourtsIndia gives no change signal (RefreshTicket.changed is None), so the sweep refreshes a CNR at most
# fortnightly (§11.5); drop this to sweep weekly once the primary provider has Capability.CHANGE_SIGNAL.
SWEEP_EVERY = timedelta(days=13)
sleep = asyncio.sleep  # tests replace it

MATTER = """
select m.cnr, c.fetched_at from public.matters m left join public.court_cases c on c.cnr = m.cnr
where m.id = :id and m.org_id = :o and m.deleted_at is null and m.tracking = 'auto' and m.cnr is not null
"""
# Heard on :day: the court's next date was that day, or it was on that day's cause list. Not updated yet: no court
# record yet, or it still shows no hearing on that day and the case is open (pending, or a status the provider
# didn't name).
HEARD = """
select distinct m.cnr from public.matters m left join public.court_cases c on c.cnr = m.cnr
where m.tracking = 'auto' and m.deleted_at is null
  and (c.next_hearing_date = cast(:day as date)
       or exists (select 1 from public.cause_list_entries e where e.cnr = m.cnr and e.list_date = cast(:day as date)))
  and (not cast(:not_updated as boolean) or c.cnr is null
       or (c.status in ('pending', 'unknown')
           and (c.last_hearing_date is null or c.last_hearing_date < cast(:day as date))))
order by m.cnr
"""
# For the weekly sweep: CNRs never fetched (an import that failed or was paused part-way), and open cases (pending,
# or a status the provider didn't name) with no next date or one already past, not fetched for SWEEP_EVERY.
STALE = """
select distinct m.cnr from public.matters m left join public.court_cases c on c.cnr = m.cnr
where m.tracking = 'auto' and m.deleted_at is null and m.cnr is not null
  and (c.cnr is null
       or (c.status in ('pending', 'unknown') and (c.next_hearing_date is null or c.next_hearing_date < :today)
           and (c.fetched_at is null or c.fetched_at < :before)))
order by m.cnr
"""


def get_case(cnr: str) -> Callable[[CourtDataProvider], Awaitable[CaseRecord]]:
    return lambda p: p.get_case(cnr)


def bulk_refresh(cnrs: list[str]) -> Callable[[CourtDataProvider], Awaitable[RefreshTicket]]:
    return lambda p: p.bulk_refresh(cnrs)


async def store(record: CaseRecord, now: datetime) -> list[Event]:
    """Change detection and fan-out in one transaction (§11.6); new orders go to the order pipeline after commit."""
    async with db.engine().begin() as c:
        events = await apply_case(c, record, now)
        orders = await fan_out(c, record.cnr, events)
    for order_id in orders:
        jobs.send(ORDER_PIPELINE, str(order_id))
    return events


async def sync(cnr: str) -> None:
    """Fan-out from the cached court record: no provider call, no events."""
    async with db.engine().begin() as c:
        await fan_out(c, cnr)


async def tracked(matter_id: str, org_id: str | None) -> dict[str, Any] | None:
    """The matter's CNR and when its court record was fetched; None unless it is live and auto-tracked."""
    async with db.engine().connect() as c:
        found = await db.rows(c, MATTER, id=matter_id, o=org_id)
    return found[0] if found else None


async def fetch(job: jobs.Job, r: Redis, now: datetime) -> dict[str, Any] | None:
    """FETCH_CASES (§11.4 step 7): get_case for the matters a user just added, or fan-out from a court record under
    6 h old. Resumes after the matters an earlier run of this job finished (`done` counts through `matter_ids` in
    order). A retryable provider error retries the task (jobs.run); a CNR the provider doesn't know (`not_found`) or
    rejects (`failed`, with the provider's code) is reported and the rest are still fetched."""
    ids: list[str] = job.input["matter_ids"]
    progress: dict[str, Any] = {"done": 0, "total": len(ids), "not_found": [], "failed": [], **job.progress}
    async with CourtData(r, now.date()) as cd:
        for matter_id in ids[progress["done"] :]:
            matter = await tracked(matter_id, job.org_id)
            if matter and matter["fetched_at"] and matter["fetched_at"] >= now - FETCH_CACHE:
                await sync(matter["cnr"])
            elif matter:
                cnr = matter["cnr"]
                try:
                    record = await cd.call(Spend.ORG, Capability.CASE_DETAIL, get_case(cnr), org_id=job.org_id, cnr=cnr)
                except CaseNotFound:
                    progress["not_found"].append(matter_id)
                except ProviderError as e:
                    if e.retryable:
                        raise
                    progress["failed"].append({"matter_id": matter_id, "code": e.code})
                else:
                    await store(record, now)
            progress["done"] += 1
            if not await jobs.set_progress(job.id, progress):
                return None  # cancelled: what is done stays
    return progress


async def refresh(job: jobs.Job, r: Redis, now: datetime) -> dict[str, Any]:
    """REFRESH_CASE, the on-demand refresh (§11.5; the API holds its 6-hour slot): org-costed, so the budgets are
    checked first. A court record under 15 min old is reused; otherwise refresh_case, wait until the provider says
    the data is ready, get_case. A deleted or manual matter has nothing to refresh."""
    matter = await tracked(job.input["matter_id"], job.org_id)
    if matter is None:
        return {"refreshed": False}
    cnr = matter["cnr"]
    async with CourtData(r, now.date()) as cd:
        await cd.check(Spend.ORG, job.org_id)
        if matter["fetched_at"] and matter["fetched_at"] >= now - REFRESH_CACHE:
            await sync(cnr)
            return {"refreshed": True, "cached": True, "events": []}
        ticket = await cd.call(Spend.ORG, Capability.REFRESH, lambda p: p.refresh_case(cnr), org_id=job.org_id, cnr=cnr)
        await sleep(min(ticket.ready_in_s, MAX_WAIT_S))
        record = await cd.call(Spend.ORG, Capability.CASE_DETAIL, get_case(cnr), org_id=job.org_id, cnr=cnr)
    events = await store(record, now)
    return {"refreshed": True, "cached": False, "events": sorted(e.kind for e in events)}


async def refresh_cnrs(r: Redis, spend: Spend, cnrs: list[str], now: datetime) -> dict[str, Any]:
    """The scheduled refresh: bulk_refresh in chunks of 50, wait once for the slowest ticket, then get_case for each
    accepted CNR (unless the provider says it didn't change) and store it. A budget stop ends the run; a failed call
    skips its CNRs, which the next attempt or the weekly sweep picks up."""
    out: dict[str, Any] = {"cnrs": len(cnrs), "fetched": 0, "events": 0}
    async with CourtData(r, now.date()) as cd:
        try:
            tickets: list[RefreshTicket] = []
            for i in range(0, len(cnrs), CHUNK):
                chunk = cnrs[i : i + CHUNK]
                if spend is Spend.SHARED:
                    chunk = await cd.drop_over_budget(chunk)
                if not chunk:
                    continue
                try:
                    tickets.append(await cd.call(spend, Capability.BULK_REFRESH, bulk_refresh(chunk), n=len(chunk)))
                except ProviderError as e:
                    log.warning("bulk_refresh_failed", code=e.code, cnrs=len(chunk))
            if tickets:
                await sleep(min(max(t.ready_in_s for t in tickets), MAX_WAIT_S))
            for cnr in [c for t in tickets if t.changed is not False for c in t.cnrs]:
                try:
                    record = await cd.call(spend, Capability.CASE_DETAIL, get_case(cnr), cnr=cnr)
                except ProviderError as e:
                    log.warning("refresh_failed", cnr=cnr, code=e.code)
                    continue
                out["fetched"] += 1
                out["events"] += len(await store(record, now))
        except Paused as e:
            log.warning("refresh_paused", spend=spend.value, code=e.code)
            out["paused"] = e.code
    return out


async def heard(day: date, *, not_updated: bool = False) -> list[str]:
    async with db.engine().connect() as c:
        return [row["cnr"] for row in await db.rows(c, HEARD, day=day, not_updated=not_updated)]


async def stale(now: datetime) -> list[str]:
    """For the weekly sweep (STALE)."""
    async with db.engine().connect() as c:
        return [row["cnr"] for row in await db.rows(c, STALE, today=now.date(), before=now - SWEEP_EVERY)]


async def post_hearing(r: Redis, now: datetime) -> dict[str, Any] | None:
    """19:30: CNRs heard today. PROTECTED: no budget pauses it, so hearing outcomes keep arriving."""
    async with jobs.scheduled(r, f"sched:post_hearing_refresh:{now.date()}") as first:
        return await refresh_cnrs(r, Spend.PROTECTED, await heard(now.date()), now) if first else None


async def retry(r: Redis, now: datetime, attempt: int) -> dict[str, Any] | None:
    """08:00 (attempt 1) and 19:30 (attempt 2) the next day: CNRs heard yesterday that still show no update.
    Attempt 2 leaves out the CNRs heard again today: post_hearing_refresh fetches those at the same time."""
    async with jobs.scheduled(r, f"sched:post_hearing_retry:{now.date()}:{attempt}") as first:
        if not first:
            return None
        cnrs = await heard(now.date() - timedelta(days=1), not_updated=True)
        if attempt == 2:
            today = set(await heard(now.date()))
            cnrs = [c for c in cnrs if c not in today]
        return await refresh_cnrs(r, Spend.PLATFORM if attempt == 1 else Spend.SHARED, cnrs, now)


async def sweep(r: Redis, now: datetime) -> dict[str, Any] | None:
    async with jobs.scheduled(r, f"sched:weekly_sweep:{now.date()}") as first:
        return await refresh_cnrs(r, Spend.PLATFORM, await stale(now), now) if first else None


@app.task(name=tasks.FETCH_CASES, bind=True, max_retries=5)
def fetch_cases(self: Task, job_id: str) -> None:
    jobs.run_job(self, job_id, lambda job, r: fetch(job, r, now_ist()))


@app.task(name=tasks.REFRESH_CASE, bind=True, max_retries=5)
def refresh_case(self: Task, job_id: str) -> None:
    jobs.run_job(self, job_id, lambda job, r: refresh(job, r, now_ist()))


@app.task(name=POST_HEARING_REFRESH)
def post_hearing_refresh() -> dict[str, Any] | None:
    return jobs.run_task(lambda r: post_hearing(r, now_ist()))


@app.task(name=POST_HEARING_RETRY)
def post_hearing_retry(attempt: int = 1) -> dict[str, Any] | None:
    return jobs.run_task(lambda r: retry(r, now_ist(), attempt))


@app.task(name=WEEKLY_SWEEP)
def weekly_sweep() -> dict[str, Any] | None:
    return jobs.run_task(lambda r: sweep(r, now_ist()))
