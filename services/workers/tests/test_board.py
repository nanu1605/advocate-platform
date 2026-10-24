"""Tomorrow's Board (spec §4.2): the expected-slot and clash heuristics against config/fixtures/board_clash.yaml, the
board rebuild that keeps members' choices, and the 07:30 today_morning message (§13.1)."""

from collections.abc import AsyncIterator
from datetime import date, datetime, time, timedelta
from pathlib import Path

import pytest
import yaml
from conftest import COURT_DC_IND, COURT_MPHC_JBP, Factory, sql
from redis.asyncio import Redis

from advocate_shared.ist import IST
from advocate_workers import db, notify
from advocate_workers.board import Entry, build_board, clash_groups, expected_slot, run_today_morning

FIXTURE = yaml.safe_load((Path(__file__).parents[3] / "config/fixtures/board_clash.yaml").read_text("utf-8"))
DAY = date(2033, 3, 8)  # far from other tests' dates: boards are rebuilt per organisation, but keep runs apart


def _time(value: str | None) -> time | None:
    return time.fromisoformat(value) if value else None


@pytest.mark.parametrize("case", FIXTURE["slots"], ids=lambda c: f"{c['level']}-{c['item']}")
def test_expected_slot(case: dict):
    assert expected_slot(case["level"], case["item"]) == _time(case["slot"])


@pytest.mark.parametrize("case", FIXTURE["clashes"], ids=lambda c: c["name"])
def test_clash_groups(case: dict):
    entries = [
        Entry(e["key"], e["court"], _time(e["slot"]), e.get("assignee"), e.get("proxy", False)) for e in case["entries"]
    ]
    assert clash_groups(entries, case.get("advocate")) == case["groups"]


async def board(org_id: str, day: date = DAY) -> dict[str, dict]:
    found = await sql(
        "select matter_id::text, court_no, item_no, expected_slot, clash_group, assignee_id::text, proxy_arranged "
        "from public.board_entries where org_id = :o and board_date = :d and is_current",
        o=org_id,
        d=day,
    )
    return {r.pop("matter_id"): r for r in found}


async def build(org_id: str, day: date = DAY) -> int:
    async with db.engine().begin() as c:
        return await build_board(c, org_id, day)


async def listed(org_id: str, matter: str, court_no: str, item_no: str, day: date = DAY) -> None:
    """An organisation's cause-list row, as cause_list_tomorrow writes it (court from the matter)."""
    await sql(
        "insert into public.org_cause_list_entries (org_id, matter_id, list_date, court_id, court_no, item_no) "
        "select org_id, id, :d, court_id, :n, :i from public.matters where id = :m",
        d=day, n=court_no, i=item_no, m=matter,
    )  # fmt: skip


@pytest.fixture
async def jabalpur_holiday() -> AsyncIterator[None]:
    """MPHC Jabalpur closed on DAY by its verified calendar."""
    await sql(
        "insert into public.court_holidays (court_id, date, kind, status, source) "
        "values (:c, :d, 'holiday', 'VERIFIED', 'test_board')",
        c=COURT_MPHC_JBP, d=DAY,
    )  # fmt: skip
    yield
    await sql("delete from public.court_holidays where source = 'test_board' and date = :d", d=DAY)


async def test_board_rebuild_keeps_members_choices_and_drops_stale_rows(make: Factory, jabalpur_holiday: None):
    org = await make.org("Neha Sharma", members={"Rakesh Jain": "junior"})
    rakesh = org.users["Rakesh Jain"]
    hc = await make.matter(org, make.cnr(), next_hearing_date=DAY)
    dc = await make.matter(org, make.cnr(), next_hearing_date=DAY, court_id=COURT_DC_IND)
    assigned = await make.matter(org, make.cnr(), next_hearing_date=DAY, assigned_to=rakesh, court_no="9")
    early = await make.matter(org, make.cnr(), next_hearing_date=DAY + timedelta(days=30))
    manual = await make.matter(org, tracking="manual", court_id=COURT_DC_IND)
    await sql(
        "insert into public.hearings (org_id, matter_id, date, court_no, item_no, source) values "
        "(:o, :m, :d, '5', '20', 'manual'), (:o, :m, :later, null, null, 'manual')",
        o=org.id, m=manual, d=DAY, later=DAY + timedelta(days=7),
    )  # fmt: skip
    await make.matter(org, make.cnr(), next_hearing_date=DAY, deleted=True)
    await make.matter(org, make.cnr(), next_hearing_date=DAY, tracking="off")
    await make.matter(org, make.cnr(), next_hearing_date=DAY + timedelta(days=1))
    await make.matter(org, make.cnr(), next_hearing_date=DAY, court_id=COURT_MPHC_JBP)  # the court is closed
    sitting = await make.matter(org, make.cnr(), next_hearing_date=DAY, court_id=COURT_MPHC_JBP)
    await listed(org.id, hc, "12", "1")  # 10:30 at MPHC Indore
    await listed(org.id, dc, "3", "1")  # 11:00 at the District Court: same unassigned advocate, so a clash
    await listed(org.id, early, "4", "S-2")  # listed before its next date; supplementary item, no slot
    await listed(org.id, sitting, "2", "S-1")  # a published list beats the holiday calendar

    assert await build(org.id) == 6
    entries = await board(org.id)
    assert entries == {
        hc: {"court_no": "12", "item_no": "1", "expected_slot": time(10, 30), "clash_group": 1, "assignee_id": None,
             "proxy_arranged": False},
        dc: {"court_no": "3", "item_no": "1", "expected_slot": time(11, 0), "clash_group": 1, "assignee_id": None,
             "proxy_arranged": False},
        assigned: {"court_no": "9", "item_no": None, "expected_slot": None, "clash_group": None,
                   "assignee_id": rakesh, "proxy_arranged": False},
        early: {"court_no": "4", "item_no": "S-2", "expected_slot": None, "clash_group": None, "assignee_id": None,
                "proxy_arranged": False},
        manual: {"court_no": "5", "item_no": "20", "expected_slot": time(12, 35), "clash_group": None,
                 "assignee_id": None, "proxy_arranged": False},
        sitting: {"court_no": "2", "item_no": "S-1", "expected_slot": None, "clash_group": None, "assignee_id": None,
                  "proxy_arranged": False},
    }  # fmt: skip

    # The owner assigns herself one of the two: still the same person as the unassigned one, so still a clash.
    await sql("update public.board_entries set assignee_id = :u where matter_id = :m", u=org.owner_id, m=hc)
    await build(org.id)
    assert {m: e["clash_group"] for m, e in (await board(org.id)).items() if m in (hc, dc)} == {hc: 1, dc: 1}

    # Members act on the board (§4.2: Assign to, Mark proxy arranged); then the court data moves on.
    await sql("update public.board_entries set assignee_id = :u where matter_id = :m", u=rakesh, m=hc)
    await sql("update public.board_entries set proxy_arranged = true where matter_id = :m", m=dc)
    await sql("update public.matters set next_hearing_date = :d where id = :m", d=DAY + timedelta(days=14), m=assigned)
    await sql("update public.org_cause_list_entries set item_no = '23' where matter_id = :m", m=hc)
    [before] = await sql("select updated_at from public.board_entries where matter_id = :m", m=manual)

    assert await build(org.id) == 5
    entries = await board(org.id)
    assert assigned not in entries  # no longer on that day's board
    assert (entries[hc]["assignee_id"], entries[hc]["expected_slot"], entries[hc]["clash_group"]) == (
        rakesh,
        time(11, 58),
        None,
    )
    assert (entries[dc]["proxy_arranged"], entries[dc]["clash_group"]) == (True, None)
    [after] = await sql("select updated_at from public.board_entries where matter_id = :m", m=manual)
    assert after == before  # unchanged rows aren't rewritten, so devices don't re-sync them


@pytest.fixture
async def morning_key(r: Redis) -> AsyncIterator[str]:
    key = f"sched:today_morning:{DAY}"
    yield key
    await r.delete(key)


async def test_today_morning_names_the_first_matter(
    make: Factory, r: Redis, morning_key: str, monkeypatch: pytest.MonkeyPatch
):
    org = await make.org("Neha Sharma", members={"Rakesh Jain": ("advocate", "hi")})
    first = await make.matter(org, make.cnr(), next_hearing_date=DAY)
    second = await make.matter(org, make.cnr(), next_hearing_date=DAY, court_id=COURT_DC_IND)
    await listed(org.id, first, "7", "3")  # 10:38
    await listed(org.id, second, "2", "1")  # 11:00
    await build(org.id)
    empty = await make.org("Arun Mehta")
    broken = await make.org("Kavita Rao")
    await listed(broken.id, await make.matter(broken, make.cnr(), next_hearing_date=DAY), "3", "1")
    await build(broken.id)
    summary = notify.board_summary

    async def fails_for_one(conn, kind, org_id, board_date):  # one organisation's message can't be written
        if str(org_id) == broken.id:
            raise RuntimeError("bad row")
        return await summary(conn, kind, org_id, board_date)

    monkeypatch.setattr(notify, "board_summary", fails_for_one)

    now = datetime.combine(DAY, time(7, 30), IST)
    assert await run_today_morning(r, now) == 2
    assert await run_today_morning(r, now) == 0  # the beat firing twice sends nothing more
    found = await sql(
        "select p.full_name, n.kind, n.title, n.body, n.data->>'link' as link from public.notifications n "
        "join public.profiles p on p.id = n.user_id where n.org_id = any(cast(:o as uuid[])) order by p.full_name",
        o=[org.id, empty.id],
    )
    assert found == [
        {"full_name": "Neha Sharma", "kind": "today_morning", "title": "Today", "link": "/today",
         "body": "Today: 2 matters. First at MPHC Indore, Court 7, item 3."},
        {"full_name": "Rakesh Jain", "kind": "today_morning", "title": "आज", "link": "/today",
         "body": "आज: 2 केस। पहला: MPHC इंदौर, कोर्ट 7, आइटम 3।"},
    ]  # fmt: skip
