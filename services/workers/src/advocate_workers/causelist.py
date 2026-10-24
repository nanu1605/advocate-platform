"""cause_list_tomorrow at 18:30, 20:30 and 22:00, and advocate_watch (spec §11.5, §4.2, §13.1).

The provider interface has no free "available dates" call (§11.5 assumes one), so attempt 1 checks every tracked
CNR whose court next date is tomorrow, tomorrow being a court day for its court; a CNR whose list isn't published
yet comes back without a listing, and attempts 2 and 3 check only those again. The check is PROTECTED spend
(§11.8), never paused. Each attempt then rebuilds every board for tomorrow and rewrites the one "Tomorrow" message
per organisation. If the provider fails (or can't even be set up), the boards are still built from the court next
dates and the affected organisations get one sync_issue that evening. One organisation's failure never holds up
another's board.

advocate_watch (feature flag `advocate_watch`, off until spike 11e confirms the provider filters by advocate and
date) searches tomorrow's cause lists by each advocate member's name in their practice courts, costed to the
organisation (paused first): tracked cases listed before their court next date (or with none) go on the board with a
listed_unexpectedly alert, untracked ones go to Found for you."""

import itertools
from collections.abc import Collection, Iterable
from datetime import date, datetime, time, timedelta
from uuid import UUID

import structlog
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_shared.ist import now_ist
from advocate_workers import db, find, jobs, notify
from advocate_workers.board import build_board
from advocate_workers.celery_app import ADVOCATE_WATCH, CAUSE_LIST_TOMORROW, app
from advocate_workers.courts import CourtData, Paused, Spend, court_ids
from court_data.models import Capability, CauseListHit, ProviderError

log = structlog.get_logger()

BATCH = 50
NEXT_ATTEMPT = {1: time(20, 30), 2: time(22, 0)}  # celery_app's beat schedule, for "We'll retry at 8:30 pm"

DUE = """
select distinct m.cnr from public.matters m
where m.tracking = 'auto' and m.deleted_at is null and m.cnr is not null and m.next_hearing_date = :d
  and public.is_court_day(m.court_id, :d)
  and (cast(:every as boolean)
       or not exists (select 1 from public.cause_list_entries e where e.cnr = m.cnr and e.list_date = :d))
order by m.cnr
"""
STORE = """
insert into public.cause_list_entries (cnr, list_date, court_id, case_ref, court_no, item_no, bench, list_type, source,
  fetched_at)
select u.cnr, cast(:d as date), u.court_id, u.case_ref, u.court_no, u.item_no, u.bench, u.list_type,
  cast(:source as text), cast(:now as timestamptz)
from unnest(cast(:cnr as text[]), cast(:court as uuid[]), cast(:ref as text[]), cast(:cno as text[]),
  cast(:ino as text[]), cast(:bench as text[]), cast(:lt as text[]))
  as u(cnr, court_id, case_ref, court_no, item_no, bench, list_type)
on conflict (cnr, list_date) do update set court_id = excluded.court_id, case_ref = excluded.case_ref,
  court_no = excluded.court_no, item_no = excluded.item_no, bench = excluded.bench, list_type = excluded.list_type,
  source = excluded.source, fetched_at = excluded.fetched_at
"""
FAN_OUT = """
insert into public.org_cause_list_entries (org_id, matter_id, cause_list_entry_id, list_date, court_id, court_no,
  item_no, bench, list_type)
select m.org_id, m.id, e.id, e.list_date, coalesce(e.court_id, m.court_id), e.court_no, e.item_no, e.bench, e.list_type
from public.cause_list_entries e
join public.matters m on m.cnr = e.cnr and m.tracking = 'auto' and m.deleted_at is null
where e.cnr = any(:cnrs) and e.list_date = :d
on conflict (matter_id, cause_list_entry_id) do update set court_id = excluded.court_id,
  court_no = excluded.court_no, item_no = excluded.item_no, bench = excluded.bench, list_type = excluded.list_type,
  is_current = true
where (org_cause_list_entries.court_id, org_cause_list_entries.court_no, org_cause_list_entries.item_no,
       org_cause_list_entries.bench, org_cause_list_entries.list_type, org_cause_list_entries.is_current)
  is distinct from (excluded.court_id, excluded.court_no, excluded.item_no, excluded.bench, excluded.list_type, true)
"""
# Every organisation with a board for the date, or with one that must now be emptied.
BOARD_ORGS = """
select org_id from public.matters where deleted_at is null and tracking = 'auto' and next_hearing_date = :d
union select org_id from public.org_cause_list_entries where list_date = :d
union select h.org_id from public.hearings h join public.matters m on m.id = h.matter_id
  where m.tracking = 'manual' and m.deleted_at is null and h.date = :d and h.deleted_at is null
union select org_id from public.board_entries where board_date = :d
"""
TRACKING_ORGS = """
select distinct org_id from public.matters where cnr = any(:cnrs) and tracking = 'auto' and deleted_at is null
"""
EARLY = """
select m.id, m.org_id, m.cnr, m.case_type, m.case_number, m.case_year, m.title, c.short_name, c.short_name_hi,
       e.court_no, e.item_no
from public.cause_list_entries e
join public.matters m on m.cnr = e.cnr and m.tracking = 'auto' and m.deleted_at is null
left join public.courts c on c.id = coalesce(e.court_id, m.court_id)
where e.cnr = any(:cnrs) and e.list_date = :d and (m.next_hearing_date is null or m.next_hearing_date > e.list_date)
"""
# A cause-list search returns no advocate names, so the name match can't be confirmed: always low / partial_name.
FOUND = """
insert into public.found_cases (org_id, user_id, cnr, court_id, court_no, next_date, case_status, confidence,
  match_reason, source)
select cast(:o as uuid), cast(:u as uuid), e.cnr, e.court_id, e.court_no, e.list_date, 'pending', 'low', 'partial_name',
  'advocate_watch'
from public.cause_list_entries e
where e.cnr = any(:cnrs) and e.list_date = :d
  and not exists (select 1 from public.matters m where m.org_id = cast(:o as uuid) and m.cnr = e.cnr
                  and m.deleted_at is null)
on conflict (org_id, cnr) do nothing
"""


async def flag_on(key: str) -> bool:
    async with db.engine().connect() as c:
        on = await c.execute(text("select value = to_jsonb(true) from public.feature_flags where key = :k"), {"k": key})
        return bool(on.scalar())


async def store(
    conn: AsyncConnection, provider: str, day: date, hits: Iterable[CauseListHit], now: datetime
) -> list[str]:
    """Upsert the day's listings into cause_list_entries (one per CNR and day, so reruns update) and fan them out to
    every organisation tracking the CNR (org_cause_list_entries). Returns the listed CNRs."""
    found = {h.cnr: h for h in hits if h.cnr and h.list_date == day}
    if not found:
        return []
    listed = list(found.values())
    courts = await court_ids(conn, provider, (h.court_code for h in listed))
    await conn.execute(
        text(STORE),
        {
            "d": day,
            "source": provider,
            "now": now,
            "cnr": list(found),
            "court": [courts.get(h.court_code or "") for h in listed],
            "ref": [h.case_ref for h in listed],
            "cno": [h.court_no for h in listed],
            "ino": [h.item_no for h in listed],
            "bench": [h.bench for h in listed],
            "lt": [h.list_type for h in listed],
        },
    )
    await conn.execute(text(FAN_OUT), {"cnrs": list(found), "d": day})
    return list(found)


async def publish(
    day: date, orgs: Iterable[UUID], troubled: Collection[UUID] = (), retry_at: time | None = None
) -> None:
    """Rebuild each organisation's board for `day` and (re)write its one "Tomorrow" message; `troubled` organisations
    (provider failed for their cases) also get that evening's sync_issue."""
    for org in orgs:
        try:
            async with db.engine().begin() as c:
                await build_board(c, str(org), day)
                await notify.board_summary(c, "tomorrow_board", org, day)
                if org in troubled:
                    await notify.sync_issue(c, org, day - timedelta(days=1), retry_at)
        except Exception:
            log.exception("board_publish_failed", org_id=str(org))  # the next attempt rebuilds it


async def run_cause_list(r: Redis, now: datetime, attempt: int = 1) -> dict[str, int]:
    """One attempt (1, 2 or 3) of the evening cause-list check for tomorrow; see the module docstring."""
    today = now.date()
    tomorrow = today + timedelta(days=1)
    async with jobs.scheduled(r, f"sched:cause_list_tomorrow:{today}:{attempt}") as first:
        if not first:
            return {}
        async with db.engine().connect() as c:
            due = [row["cnr"] for row in await db.rows(c, DUE, d=tomorrow, every=attempt == 1)]
        hits: list[CauseListHit] = []
        failed: list[str] = []
        provider = ""
        try:
            async with CourtData(r, today) as cd:
                provider = cd.provider
                for batch in itertools.batched(due, BATCH, strict=False):
                    try:
                        hits += await cd.call(
                            Spend.PROTECTED,
                            Capability.CAUSELIST_CNR_BATCH,
                            lambda p, b=list(batch): p.check_cause_list(b, tomorrow),
                            n=len(batch),
                        )
                    except ProviderError as e:
                        log.warning("cause_list_check_failed", code=e.code, cnrs=len(batch), attempt=attempt)
                        failed += batch
        except ProviderError as e:  # no provider at all (e.g. live without a key): every check failed
            log.error("cause_list_no_provider", code=e.code, attempt=attempt)
            failed = due
        async with db.engine().begin() as c:
            listed = await store(c, provider, tomorrow, hits, now)
            orgs = [row["org_id"] for row in await db.rows(c, BOARD_ORGS, d=tomorrow)]
            troubled = {row["org_id"] for row in await db.rows(c, TRACKING_ORGS, cnrs=failed)}
        await publish(tomorrow, orgs, troubled, NEXT_ATTEMPT.get(attempt))
        if attempt == 1 and await flag_on("advocate_watch"):
            jobs.send(ADVOCATE_WATCH)
        return {"checked": len(due), "listed": len(listed), "failed": len(failed), "boards": len(orgs)}


async def run_advocate_watch(r: Redis, now: datetime) -> dict[str, int]:
    """Tomorrow's cause lists searched by each advocate member's name (owner or advocate role) in their practice
    courts (find.Search: the courts in their profile, else every court in their Bar Council's state; a member with
    neither is skipped); see the module docstring. Stops at the global daily cap and skips organisations over their
    monthly budget.
    ponytail: one page (100 listings) per advocate; page through once spike 11e shows the provider's limits."""
    today = now.date()
    tomorrow = today + timedelta(days=1)
    async with jobs.scheduled(r, f"sched:advocate_watch:{today}") as first:
        if not first or not await flag_on("advocate_watch"):
            return {}
        advocates = await find.advocates()
        found: list[tuple[dict, list[CauseListHit]]] = []
        over_budget: set[str] = set()
        async with CourtData(r, today) as cd:
            for a in advocates:
                if a["org_id"] in over_budget:
                    continue
                s = await find.Search.start(
                    cd, a["practice_court_ids"], a["bar_council_state"],
                    org_id=a["org_id"], user_id=a["user_id"], name=a["full_name"], source="advocate_watch",
                )  # fmt: skip
                if not s.practice:
                    continue
                query = s.cause_list_query(tomorrow)
                try:
                    hits = await cd.call(
                        Spend.ORG,
                        Capability.CAUSELIST_SEARCH,
                        lambda p, q=query: p.search_cause_list(q),
                        org_id=a["org_id"],
                    )
                except Paused as e:
                    if e.code == "COURT_DATA_PAUSED":
                        break
                    over_budget.add(a["org_id"])
                    continue
                except ProviderError as e:
                    log.warning("advocate_watch_failed", code=e.code)
                    continue
                found.append((a, [h for h in hits if h.cnr and h.list_date == tomorrow]))
        async with db.engine().begin() as c:
            listed = await store(c, cd.provider, tomorrow, (h for _, hits in found for h in hits), now)
            early = await db.rows(c, EARLY, cnrs=listed, d=tomorrow)
            for m in early:
                where = notify.Position(m["short_name"], m["short_name_hi"], m["court_no"], m["item_no"])
                await notify.listed_unexpectedly(c, m, tomorrow, where)
            for a, hits in found:
                await c.execute(
                    text(FOUND), {"o": a["org_id"], "u": a["user_id"], "cnrs": [h.cnr for h in hits], "d": tomorrow}
                )
            orgs = [row["org_id"] for row in await db.rows(c, TRACKING_ORGS, cnrs=listed)]
        await publish(tomorrow, orgs)
        return {"searched": len(found), "listed": len(listed), "early": len(early), "boards": len(orgs)}


@app.task(name=CAUSE_LIST_TOMORROW)
def cause_list_tomorrow(attempt: int = 1) -> dict[str, int]:
    return jobs.run_task(lambda r: run_cause_list(r, now_ist(), attempt))


@app.task(name=ADVOCATE_WATCH)
def advocate_watch() -> dict[str, int]:
    return jobs.run_task(lambda r: run_advocate_watch(r, now_ist()))
