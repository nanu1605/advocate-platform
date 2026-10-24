"""Tomorrow's Board and the clash heuristic (spec §4.2), and the 07:30 today_morning notification (§13.1).

A matter is on an organisation's board for a date when it has a cause-list entry that day, or (on a court day for
its court: not a Sunday or a VERIFIED holiday) its court next date is that day (auto tracking) or it has a hearing
dated that day (manual tracking). Members' choices on a board row (assignee, proxy arranged) survive every rebuild.

Expected slots come from the item number and the court level's sitting (SITTINGS). The sitting times are a
heuristic, listed as unverified in docs/legal-verification.md: a slot is an estimate, never a fact shown as one.
Two entries clash when they are in different court complexes, their windows (slot .. slot + CLASH_WINDOW_MIN)
overlap, the same person appears (same assignee; unassigned counts as the organisation's advocate, its owner) and
neither has a proxy arranged. Fixture cases: config/fixtures/board_clash.yaml; the heuristic is ADR 0012."""

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date, datetime, time

import structlog
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_shared.ist import now_ist
from advocate_workers import db, jobs, notify
from advocate_workers.celery_app import TODAY_MORNING, app

log = structlog.get_logger()


@dataclass(frozen=True, slots=True)
class Sitting:
    start: time
    per_item_min: int
    lunch: tuple[time, time]
    rises: time  # items that would come up after this get no slot


# DRAFT – VERIFY (docs/legal-verification.md): typical sittings, not published court timings.  # noqa: RUF003
SITTINGS = {
    "SC": Sitting(time(10, 30), 3, (time(13, 0), time(14, 0)), time(16, 0)),
    "HC": Sitting(time(10, 30), 4, (time(13, 30), time(14, 30)), time(16, 30)),
    "DC": Sitting(time(11, 0), 5, (time(14, 0), time(14, 30)), time(17, 0)),
    "TRIBUNAL": Sitting(time(10, 30), 5, (time(13, 30), time(14, 30)), time(16, 30)),
}
CLASH_WINDOW_MIN = 60  # a hearing plus the walk or drive between complexes; DRAFT – VERIFY as above  # noqa: RUF003


def _minutes(t: time) -> int:
    return t.hour * 60 + t.minute


def expected_slot(level: str | None, item_no: str | None) -> time | None:
    """Estimated start of item `item_no` in a court of `level`: session start plus a fixed time per item, skipping
    lunch. None for an unknown level, a non-numeric item ("S-12", supplementary lists) or one past the sitting."""
    sitting = SITTINGS.get(level or "")
    item = (item_no or "").strip()
    if sitting is None or not item.isdecimal() or int(item) < 1:
        return None
    at = _minutes(sitting.start) + (int(item) - 1) * sitting.per_item_min
    lunch_start, lunch_end = (_minutes(t) for t in sitting.lunch)
    if at >= lunch_start:
        at += lunch_end - lunch_start
    return time(at // 60, at % 60) if at < _minutes(sitting.rises) else None


@dataclass(frozen=True, slots=True)
class Entry:
    key: str  # matter id
    court_id: str | None
    slot: time | None
    assignee: str | None = None
    proxy: bool = False


def clashes(a: Entry, b: Entry, advocate: str | None = None) -> bool:
    """`advocate` is who an unassigned entry falls to (the organisation's owner)."""
    return bool(
        a.slot
        and b.slot
        and a.court_id
        and b.court_id
        and a.court_id != b.court_id
        and (a.assignee or advocate) == (b.assignee or advocate)
        and not (a.proxy or b.proxy)
        and abs(_minutes(a.slot) - _minutes(b.slot)) < CLASH_WINDOW_MIN
    )


def clash_groups(entries: Sequence[Entry], advocate: str | None = None) -> dict[str, int]:
    """Entries of one board (organisation and date) that clash, directly or through each other, numbered 1..n by
    their earliest slot. Entries without a clash are left out (clash_group null). Unassigned entries are
    `advocate`'s (the organisation's owner).
    ponytail: compares every pair, fine for a day's board (tens of rows)."""
    links = {e.key: [o.key for o in entries if o is not e and clashes(e, o, advocate)] for e in entries}
    groups: dict[str, int] = {}
    for e in sorted(entries, key=lambda e: (e.slot or time.max, e.key)):
        if e.key in groups or not links[e.key]:
            continue
        n, todo = len(set(groups.values())) + 1, [e.key]
        while todo:
            key = todo.pop()
            if key not in groups:
                groups[key] = n
                todo.extend(links[key])
    return groups


CANDIDATES = """
select distinct on (m.id) m.id as matter_id, m.assigned_to, coalesce(o.court_id, m.court_id) as court_id, c.level,
       coalesce(o.court_no, h.court_no, m.court_no) as court_no, coalesce(o.item_no, h.item_no) as item_no
from public.matters m
left join public.org_cause_list_entries o on o.matter_id = m.id and o.list_date = :d
left join lateral (
  select true as manual, h.court_no, h.item_no from public.hearings h
  where h.matter_id = m.id and m.tracking = 'manual' and h.date = :d and h.deleted_at is null
  order by h.created_at limit 1
) h on true
left join public.courts c on c.id = coalesce(o.court_id, m.court_id)
where m.org_id = :o and m.deleted_at is null
  and (o.id is not null
       or (((m.tracking = 'auto' and m.next_hearing_date = :d) or h.manual) and public.is_court_day(m.court_id, :d)))
order by m.id, o.created_at desc
"""
UPSERT = """
insert into public.board_entries (org_id, board_date, matter_id, court_id, court_no, item_no, expected_slot,
  assignee_id)
select cast(:o as uuid), cast(:d as date), u.m, u.c, u.n, u.i, u.s, u.a
from unnest(cast(:m as uuid[]), cast(:c as uuid[]), cast(:n as text[]), cast(:i as text[]), cast(:s as time[]),
  cast(:a as uuid[])) as u(m, c, n, i, s, a)
on conflict (matter_id, board_date) do update set court_id = excluded.court_id, court_no = excluded.court_no,
  item_no = excluded.item_no, expected_slot = excluded.expected_slot, is_current = true
where (board_entries.court_id, board_entries.court_no, board_entries.item_no, board_entries.expected_slot,
       board_entries.is_current)
  is distinct from (excluded.court_id, excluded.court_no, excluded.item_no, excluded.expected_slot, true)
"""
STALE = (
    "delete from public.board_entries where org_id = :o and board_date = :d and matter_id <> all(cast(:m as uuid[]))"
)
ENTRIES = """
select matter_id::text as key, court_id::text, expected_slot as slot, assignee_id::text as assignee,
       proxy_arranged as proxy
from public.board_entries where org_id = :o and board_date = :d
"""
GROUPS = """
update public.board_entries b set clash_group = u.g
from unnest(cast(:m as uuid[]), cast(:g as int[])) as u(m, g)
where b.board_date = :d and b.matter_id = u.m and b.clash_group is distinct from u.g
"""


async def build_board(conn: AsyncConnection, org_id: str, board_date: date) -> int:
    """Rebuild the organisation's board for `board_date`: upsert qualifying matters (a new row's assignee is the
    matter's; assignee and proxy_arranged are kept on later builds), drop rows that no longer qualify, and set the
    clash groups. Rows change only when a value does, so devices don't re-sync. Returns the number of entries."""
    found = await db.rows(conn, CANDIDATES, o=org_id, d=board_date)
    ids = [r["matter_id"] for r in found]
    await conn.execute(
        text(UPSERT),
        {
            "o": org_id,
            "d": board_date,
            "m": ids,
            "c": [r["court_id"] for r in found],
            "n": [r["court_no"] for r in found],
            "i": [r["item_no"] for r in found],
            "s": [expected_slot(r["level"], r["item_no"]) for r in found],
            "a": [r["assigned_to"] for r in found],
        },
    )
    await conn.execute(text(STALE), {"o": org_id, "d": board_date, "m": ids})
    entries = [Entry(**r) for r in await db.rows(conn, ENTRIES, o=org_id, d=board_date)]
    owner = await conn.execute(text("select owner_id::text from public.organizations where id = :o"), {"o": org_id})
    groups = clash_groups(entries, owner.scalar())
    await conn.execute(
        text(GROUPS), {"d": board_date, "m": [e.key for e in entries], "g": [groups.get(e.key) for e in entries]}
    )
    return len(entries)


async def run_today_morning(r: Redis, now: datetime) -> int:
    """07:30: "Today: 4 matters. First at MPHC Indore, Court 7." to every organisation with a board for today (built
    the evening before). Returns the notifications written."""
    today = now.date()
    async with jobs.scheduled(r, f"sched:today_morning:{today}") as first:
        if not first:
            return 0
        async with db.engine().connect() as c:
            orgs = await db.rows(
                c, "select distinct org_id from public.board_entries where board_date = :d and is_current", d=today
            )
        written = 0
        for org in orgs:
            try:
                async with db.engine().begin() as c:
                    written += await notify.board_summary(c, "today_morning", org["org_id"], today)
            except Exception:
                log.exception("today_morning_failed", org_id=str(org["org_id"]))  # the others still get theirs
        return written


@app.task(name=TODAY_MORNING)
def today_morning() -> int:
    return jobs.run_task(lambda r: run_today_morning(r, now_ist()))
