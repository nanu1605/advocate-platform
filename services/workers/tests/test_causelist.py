"""The evening cause-list check (three attempts) and advocate_watch (spec §11.5, §4.2, §13.1-13.2).

These jobs sweep every organisation with matters on the board date, so each test uses its own far-off week; the
sched:* run keys for those dates are removed afterwards."""

import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from uuid import UUID

import pytest
from conftest import COURT_DC_IND, COURT_MPHC_IND, Factory, FakeProvider, sql, unavailable
from redis.asyncio import Redis

from advocate_shared.ist import IST
from advocate_workers import courts, notify
from advocate_workers.causelist import publish, run_advocate_watch, run_cause_list
from advocate_workers.celery_app import ADVOCATE_WATCH
from court_data.models import CauseListHit, CauseListQuery, ProviderError

DAYS = [date(2033, 3, 14), date(2033, 3, 19), date(2033, 3, 20), date(2033, 3, 28), date(2033, 4, 4), date(2033, 4, 11),
        date(2033, 4, 18)]  # fmt: skip


@pytest.fixture(autouse=True)
async def sched_keys(r: Redis) -> AsyncIterator[None]:
    yield
    for day in DAYS:
        if keys := [k async for k in r.scan_iter(f"sched:*:{day}*")]:
            await r.delete(*keys)


@pytest.fixture
async def watch_flag() -> AsyncIterator[Callable[[bool], Awaitable[None]]]:
    async def turn(on: bool) -> None:
        await sql("update public.feature_flags set value = to_jsonb(cast(:v as boolean)) where key = 'advocate_watch'",
                  v=on)  # fmt: skip

    yield turn
    await turn(False)


def at(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), IST)


def hit(cnr: str, day: date, court: str = "TESTMPHCIND", court_no: str = "12", item: str = "23") -> CauseListHit:
    return CauseListHit(cnr, day, court, None, court_no, item, "daily", None, None, None)


async def bodies(*org_ids: str) -> dict[tuple[str, str], str]:
    found = await sql(
        "select p.full_name, n.kind, n.body from public.notifications n join public.profiles p on p.id = n.user_id "
        "where n.org_id = any(cast(:o as uuid[]))",
        o=list(org_ids),
    )
    assert len(found) == len({(n["full_name"], n["kind"]) for n in found})  # never two of a kind per person
    return {(n["full_name"], n["kind"]): n["body"] for n in found}


async def board(org_id: str, day: date) -> dict[str, tuple]:
    found = await sql(
        "select matter_id::text, court_no, item_no, expected_slot from public.board_entries "
        "where org_id = :o and board_date = :d",
        o=org_id,
        d=day,
    )
    return {r["matter_id"]: (r["court_no"], r["item_no"], r["expected_slot"]) for r in found}


async def test_three_attempts_check_each_case_until_listed_and_rewrite_one_message(
    make: Factory, provider: FakeProvider, r: Redis, sent: list
):
    day = DAYS[0]  # Monday
    tomorrow = day + timedelta(days=1)
    chamber = await make.org("Neha Sharma", members={"Rakesh Jain": ("advocate", "hi")})
    solo = await make.org("Arun Mehta")
    a, b = make.cnr(), make.cnr()
    case = {"case_type": "WP", "case_number": "1234", "case_year": 2024, "title": "Ramesh Kumar v. State of MP"}
    hc = await make.matter(chamber, a, next_hearing_date=tomorrow, court_no="12", **case)
    dc = await make.matter(chamber, b, next_hearing_date=tomorrow, court_no="3", court_id=COURT_DC_IND)
    other = await make.matter(solo, a, next_hearing_date=tomorrow, court_no="12")
    provider.listings[a] = hit(a, tomorrow)  # b's list isn't out yet

    assert await run_cause_list(r, at(day, 18, 30), 1) == {"checked": 2, "listed": 1, "failed": 0, "boards": 2}
    assert provider.calls == [("check_cause_list", sorted([a, b]))]
    assert await sql(
        "select cnr, court_id::text, court_no, item_no, list_type, source from public.cause_list_entries "
        "where cnr = any(:c)",
        c=[a, b],
    ) == [{"cnr": a, "court_id": COURT_MPHC_IND, "court_no": "12", "item_no": "23", "list_type": "daily",
           "source": provider.name}]  # fmt: skip
    assert await board(chamber.id, tomorrow) == {hc: ("12", "23", time(11, 58)), dc: ("3", None, None)}
    assert await board(solo.id, tomorrow) == {other: ("12", "23", time(11, 58))}
    assert await bodies(chamber.id, solo.id) == {
        ("Neha Sharma", "tomorrow_board"): "Tomorrow: 2 matters in 2 courts. First: MPHC Indore, Court 12, item 23.",
        ("Rakesh Jain", "tomorrow_board"): "कल: 2 कोर्ट में 2 केस। पहला: MPHC इंदौर, कोर्ट 12, आइटम 23।",
        ("Arun Mehta", "tomorrow_board"): "Tomorrow: 1 matter in 1 court. First: MPHC Indore, Court 12, item 23.",
    }  # no party names: the title stays out of board messages
    assert await sql("select org_id, cost_inr from public.provider_calls where provider = :p", p=provider.name) == [
        {"org_id": None, "cost_inr": Decimal("0.2")}  # a shared fetch: platform row, 2 CNRs at ₹0.10
    ]

    assert await run_cause_list(r, at(day, 18, 31), 1) == {}  # the beat firing twice runs once
    await r.delete(f"sched:cause_list_tomorrow:{day}:1")
    await run_cause_list(r, at(day, 18, 40), 1)  # a full rerun (worker died after the work) doubles nothing
    assert len(await sql("select 1 from public.cause_list_entries where cnr = :c", c=a)) == 1
    assert len(await sql("select 1 from public.org_cause_list_entries where matter_id = any(cast(:m as uuid[]))",
                         m=[hc, other])) == 2  # fmt: skip

    provider.calls.clear()
    provider.listings[b] = hit(b, tomorrow, "TESTDCIND", "3", "1")
    assert (await run_cause_list(r, at(day, 20, 30), 2))["checked"] == 1
    assert provider.calls == [("check_cause_list", [b])]  # only the case still without a listing
    assert (await board(chamber.id, tomorrow))[dc] == ("3", "1", time(11, 0))
    after = await bodies(chamber.id)
    assert after[("Neha Sharma", "tomorrow_board")] == (
        "Tomorrow: 2 matters in 2 courts. First: District Court Indore, Court 3, item 1."
    )  # the same message, rewritten
    assert after[("Rakesh Jain", "tomorrow_board")] == "कल: 2 कोर्ट में 2 केस। पहला: जिला कोर्ट इंदौर, कोर्ट 3, आइटम 1।"

    provider.calls.clear()
    assert (await run_cause_list(r, at(day, 22), 3))["checked"] == 0
    assert provider.calls == []  # everything is listed
    assert sent == []  # advocate_watch is off


async def test_sundays_and_verified_holidays_are_not_checked(make: Factory, provider: FakeProvider, r: Redis):
    saturday, sunday, monday = DAYS[1], DAYS[2], DAYS[2] + timedelta(days=1)
    org = await make.org()
    await make.matter(org, make.cnr(), next_hearing_date=sunday)
    await run_cause_list(r, at(saturday, 18, 30), 1)
    assert provider.calls == []

    closed, open_ = make.cnr(), make.cnr()
    await make.matter(org, closed, next_hearing_date=monday)  # MPHC Indore: verified holiday
    await make.matter(org, open_, next_hearing_date=monday, court_id=COURT_DC_IND)  # only a DRAFT holiday
    holidays = {"hc": COURT_MPHC_IND, "dc": COURT_DC_IND, "d": monday}
    await sql(
        "insert into public.court_holidays (court_id, date, kind, status, source) values "
        "(:hc, :d, 'holiday', 'VERIFIED', 'test_causelist'), (:dc, :d, 'holiday', 'DRAFT', 'test_causelist')",
        **holidays,
    )
    try:
        await run_cause_list(r, at(sunday, 18, 30), 1)
    finally:
        await sql("delete from public.court_holidays where source = 'test_causelist' and date = :d", d=monday)
    assert provider.calls == [("check_cause_list", [open_])]


async def test_provider_failure_still_builds_the_board_and_sends_one_sync_issue(
    make: Factory, provider: FakeProvider, r: Redis
):
    day = DAYS[3]
    tomorrow = day + timedelta(days=1)
    tracked, manual = await make.org("Neha Sharma", lang="hi"), await make.org("Arun Mehta")
    hc = await make.matter(tracked, make.cnr(), next_hearing_date=tomorrow, court_no="12")
    diary = await make.matter(manual, tracking="manual", court_id=COURT_DC_IND)
    await sql(
        "insert into public.hearings (org_id, matter_id, date, court_no, item_no, source) "
        "values (:o, :m, :d, '5', '20', 'manual')",
        o=manual.id, m=diary, d=tomorrow,
    )  # fmt: skip
    provider.fail["check_cause_list"] = unavailable()

    assert await run_cause_list(r, at(day, 18, 30), 1) == {"checked": 1, "listed": 0, "failed": 1, "boards": 2}
    assert await board(tracked.id, tomorrow) == {hc: ("12", None, None)}  # from the court next date
    assert await board(manual.id, tomorrow) == {diary: ("5", "20", time(12, 35))}
    expected = {
        ("Neha Sharma", "tomorrow_board"): "कल: 1 कोर्ट में 1 केस। पहला: MPHC इंदौर, कोर्ट 12।",
        ("Neha Sharma", "sync_issue"): "कोर्ट डेटा में देरी है। हम रात 8:30 बजे फिर कोशिश करेंगे।",
        (
            "Arun Mehta",
            "tomorrow_board",
        ): "Tomorrow: 1 matter in 1 court. First: District Court Indore, Court 5, item 20.",
    }  # the manual diary had nothing to fetch: no sync_issue there
    assert await bodies(tracked.id, manual.id) == expected
    for attempt, hour in ((2, 20), (3, 22)):
        await run_cause_list(r, at(day, hour, 30), attempt)
    assert await bodies(tracked.id, manual.id) == expected  # one sync_issue per evening
    assert (
        await sql("select status, cost_inr from public.provider_calls where provider = :p", p=provider.name)
        == [{"status": "COURT_PROVIDER_UNAVAILABLE", "cost_inr": 0}] * 3
    )


async def test_no_provider_at_all_still_builds_the_board_and_sends_a_sync_issue(
    make: Factory, r: Redis, monkeypatch: pytest.MonkeyPatch
):
    day = DAYS[5]
    tomorrow = day + timedelta(days=1)
    org = await make.org()
    hc = await make.matter(org, make.cnr(), next_hearing_date=tomorrow, court_no="12")

    def unconfigured(today: date) -> list:  # COURTDATA_LIVE=1 without a key
        raise ProviderError("COURT_PROVIDER_UNAVAILABLE", "court data is not configured", retryable=True)

    monkeypatch.setattr(courts, "make_providers", unconfigured)
    assert await run_cause_list(r, at(day, 18, 30), 1) == {"checked": 1, "listed": 0, "failed": 1, "boards": 1}
    assert await board(org.id, tomorrow) == {hc: ("12", None, None)}
    assert await bodies(org.id) == {
        ("Neha Sharma", "tomorrow_board"): "Tomorrow: 1 matter in 1 court. First: MPHC Indore, Court 12.",
        ("Neha Sharma", "sync_issue"): "Court data is delayed. We'll retry at 8:30 pm.",
    }


async def test_one_organisations_failure_leaves_the_others_their_board(
    make: Factory, r: Redis, monkeypatch: pytest.MonkeyPatch
):
    tomorrow = DAYS[6] + timedelta(days=1)
    broken, fine = await make.org("Neha Sharma"), await make.org("Arun Mehta")
    ours = {o.id: await make.matter(o, make.cnr(), next_hearing_date=tomorrow, court_no="7") for o in (broken, fine)}
    summary = notify.board_summary

    async def fails_for_one(conn, kind, org_id, board_date):  # e.g. a row the SQL can't handle
        if str(org_id) == broken.id:
            raise RuntimeError("bad row")
        return await summary(conn, kind, org_id, board_date)

    monkeypatch.setattr(notify, "board_summary", fails_for_one)
    await publish(tomorrow, [UUID(broken.id), UUID(fine.id)])
    assert await board(broken.id, tomorrow) == {}  # its transaction rolled back; the next attempt rebuilds it
    assert await board(fine.id, tomorrow) == {ours[fine.id]: ("7", None, None)}
    assert await bodies(broken.id, fine.id) == {
        ("Arun Mehta", "tomorrow_board"): "Tomorrow: 1 matter in 1 court. First: MPHC Indore, Court 7."
    }


async def test_advocate_watch_runs_only_when_flagged_and_catches_early_listings(
    make: Factory, provider: FakeProvider, r: Redis, sent: list, watch_flag, monkeypatch: pytest.MonkeyPatch
):
    day = DAYS[4]
    tomorrow = day + timedelta(days=1)
    tag = uuid.uuid4().hex[:6]  # the watch searches every advocate on the platform: answer only this test's ones
    owner, advocate, clerk = f"Kavita {tag}", f"Rakesh {tag}", f"Ram {tag}"
    org = await make.org(owner, members={advocate: ("advocate", "hi"), clerk: "clerk"})
    for name in (owner, advocate, clerk):  # practice courts: every court in the state (the clerk is never searched)
        await sql("update public.profiles set bar_council_state = 'Madhya Pradesh' where id = :u", u=org.users[name])
    early, due, late, untracked, excluded, diary = (make.cnr() for _ in range(6))
    case = {"case_type": "WP", "case_number": "77", "case_year": 2025, "title": "Ramesh Kumar v. State of MP"}
    listed_early = await make.matter(org, early, next_hearing_date=tomorrow + timedelta(days=10), **case)
    listed_due = await make.matter(org, due, next_hearing_date=tomorrow)
    # Heard today and adjourned to tomorrow; the court record (next date today) isn't updated yet: not early.
    listed_late = await make.matter(org, late, next_hearing_date=day, case_type="WP", case_number="78")
    await make.matter(org, diary, tracking="manual")
    await sql(
        "insert into public.found_cases (org_id, user_id, cnr, confidence, match_reason, source, decision) "
        "values (:o, :u, :c, 'high', 'exact_name_practice_court', 'onboarding', 'not_mine')",
        o=org.id, u=org.owner_id, c=excluded,
    )  # fmt: skip
    await sql(
        "insert into public.notification_prefs (user_id, kind, include_titles) "
        "values (:u, 'listed_unexpectedly', true)",
        u=org.owner_id,
    )
    provider.cause_list = [hit(early, tomorrow), hit(due, tomorrow, item="30"), hit(untracked, tomorrow, item="40"),
                           hit(excluded, tomorrow), hit(diary, tomorrow), hit(late, tomorrow, item="35")]  # fmt: skip
    search = provider.search_cause_list

    async def mine_only(q: CauseListQuery) -> list[CauseListHit]:
        return await search(q) if q.advocate in (owner, advocate, clerk) else []

    monkeypatch.setattr(provider, "search_cause_list", mine_only)

    await run_cause_list(r, at(day, 18, 30), 1)
    assert await run_advocate_watch(r, at(day, 18, 45)) == {}
    assert sent == [] and not [c for c in provider.calls if c[0] == "search_cause_list"]

    await watch_flag(True)
    await r.delete(f"sched:cause_list_tomorrow:{day}:1", f"sched:advocate_watch:{day}")
    await run_cause_list(r, at(day, 18, 30), 1)
    assert sent == [(ADVOCATE_WATCH, ())]
    for _ in range(2):  # a rerun doubles nothing
        await r.delete(f"sched:advocate_watch:{day}")
        await run_advocate_watch(r, at(day, 18, 45))

    searched = [q for m, q in provider.calls if m == "search_cause_list" and q.advocate in (owner, advocate, clerk)]
    assert sorted({q.advocate for q in searched}) == sorted([owner, advocate])  # advocates only, not the clerk
    assert {(q.on, q.state, q.court_complex_code) for q in searched} == {(tomorrow, "MP", None)}  # their courts
    assert (
        await sql(
            "select cost_inr from public.provider_calls where org_id = :o and operation = 'causelist_search'", o=org.id
        )
        == [{"cost_inr": Decimal("1")}] * 4
    )  # org-costed: two advocates, two runs

    alerts = {k: v for k, v in (await bodies(org.id)).items() if k[1] == "listed_unexpectedly"}
    assert alerts == {
        (owner, "listed_unexpectedly"): "WP 77/2025 · Ramesh Kumar v. State of MP is listed tomorrow (earlier than "
        "expected). MPHC Indore, Court 12, item 23.",  # titles turned on
        (advocate, "listed_unexpectedly"): "WP 77/2025 कल सूचीबद्ध है (अपेक्षा से पहले)। MPHC इंदौर, कोर्ट 12, आइटम 23।",
        (clerk, "listed_unexpectedly"): "WP 77/2025 is listed tomorrow (earlier than expected). MPHC Indore, Court 12, "
        "item 23.",
    }  # only the early one: one was due tomorrow anyway, the other was heard today and adjourned to tomorrow
    assert await board(org.id, tomorrow) == {
        listed_early: ("12", "23", time(11, 58)),
        listed_due: ("12", "30", time(12, 26)),
        listed_late: ("12", "35", time(12, 46)),
    }
    found = await sql(
        "select cnr, user_id::text, court_id::text, court_no, next_date, case_status, confidence, match_reason, "
        "source, decision from public.found_cases where org_id = :o order by source",
        o=org.id,
    )
    assert found == [
        {"cnr": untracked, "user_id": org.owner_id, "court_id": COURT_MPHC_IND, "court_no": "12",
         "next_date": tomorrow, "case_status": "pending", "confidence": "low", "match_reason": "partial_name",
         "source": "advocate_watch", "decision": "pending"},
        {"cnr": excluded, "user_id": org.owner_id, "court_id": None, "court_no": None, "next_date": None,
         "case_status": None, "confidence": "high", "match_reason": "exact_name_practice_court",
         "source": "onboarding", "decision": "not_mine"},  # an exclusion is never touched
    ]  # fmt: skip
