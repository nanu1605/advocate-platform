"""Change detection, fan-out to tracking organisations, and the notification rows it writes (spec §11.6, §13)."""

import asyncio
from dataclasses import replace
from datetime import UTC, date, datetime, time, timedelta
from uuid import UUID

from conftest import COURT_MPHC_IND, Factory, case_record, sql
from sqlalchemy import text

from advocate_workers import db, notify
from advocate_workers.diff import Event, apply_case
from advocate_workers.fanout import fan_out
from court_data.models import HearingRecord, OrderRef

NOW = datetime(2026, 10, 26, 13, 0, tzinfo=UTC)
HEARD = HearingRecord(date(2026, 10, 20), purpose="Admission", judge="Hon. A", business="Notice issued",
                      next_date=date(2026, 10, 28))  # fmt: skip
FIRST_ORDER = OrderRef("order-1.pdf", date(2026, 10, 20), "order")


async def apply(record, now=NOW) -> tuple[list[Event], list[UUID]]:
    async with db.engine().begin() as c:
        events = await apply_case(c, record, now)
        return events, await fan_out(c, record.cnr, events)


async def notifications(org_id: str) -> list[dict]:
    return await sql(
        "select u.full_name as who, n.kind, n.title, n.body, n.data from public.notifications n "
        "join public.profiles u on u.id = n.user_id where n.org_id = :o order by n.kind, u.full_name",
        o=org_id,
    )


async def test_first_fetch_is_a_baseline_and_unchanged_fetches_only_move_fetched_at(make: Factory):
    cnr = make.cnr()
    record = case_record(cnr, case_number="1234", next_hearing_date=date(2026, 10, 28), hearings=(HEARD,),
                         orders=(FIRST_ORDER,), petitioners=("Ramesh Kumar",))  # fmt: skip
    assert await apply(record) == ([], [])
    [case] = await sql(
        "select court_id::text, content_hash, search_key, fetched_at, title from public.court_cases where cnr = :c",
        c=cnr,
    )
    assert case["court_id"] == COURT_MPHC_IND  # synthetic code TESTMPHCIND, mapped without touching the database
    assert case["content_hash"] == record.content_hash()
    assert "ramesh" not in case["search_key"] and case["search_key"]  # phonetic key, not the raw name
    assert await sql("select purpose, next_date from public.court_hearings where cnr = :c", c=cnr) == [
        {"purpose": "Admission", "next_date": date(2026, 10, 28)}
    ]
    later = NOW + timedelta(hours=1)
    assert await apply(record, later) == ([], [])
    [moved] = await sql("select fetched_at from public.court_cases where cnr = :c", c=cnr)
    assert moved["fetched_at"] == later


async def test_changes_become_events_once(make: Factory):
    cnr = make.cnr()
    record = case_record(cnr, next_hearing_date=date(2026, 10, 28), orders=(FIRST_ORDER,))
    await apply(record)
    second = OrderRef("order-2.pdf", date(2026, 10, 28), "judgment")
    changed = replace(record, next_hearing_date=date(2026, 11, 5), status="disposed", orders=(FIRST_ORDER, second))
    async with db.engine().begin() as c:
        events = await apply_case(c, changed, NOW)
    [order_id] = [r["id"] for r in await sql("select id from public.court_orders where provider_ref = 'order-2.pdf' "
                                              "and cnr = :c", c=cnr)]  # fmt: skip
    assert sorted(events, key=lambda e: e.kind) == [
        Event(cnr, "new_order", "order-2.pdf", order_id),
        Event(cnr, "next_date_set", "2026-11-05"),
        Event(cnr, "status_changed", "disposed"),
    ]
    assert Event(cnr, "next_date_set", "2026-11-05").key == f"{cnr}:next_date_set:2026-11-05"
    async with db.engine().begin() as c:
        assert await apply_case(c, changed, NOW) == []
    # A next date that goes away, or a status back to pending, is a change but not an event.
    async with db.engine().begin() as c:
        assert await apply_case(c, replace(changed, next_hearing_date=None, status="pending"), NOW) == []


async def test_fan_out_syncs_tracking_matters_and_notifies_their_members(make: Factory):
    cnr = make.cnr()
    chamber = await make.org("Neha Sharma", members={"Rakesh Jain": ("advocate", "hi"), "Ram Clerk": "clerk"})
    deleted_org, manual_org = await make.org("Arun Mehta"), await make.org("Sita Verma")
    matter = await make.matter(chamber, cnr, title="as typed", court_id=None, assigned_to=chamber.users["Ram Clerk"])
    gone = await make.matter(deleted_org, cnr, deleted=True)
    manual = await make.matter(manual_org, cnr, tracking="manual")
    await sql(
        "insert into public.notification_prefs (user_id, kind, channels, include_titles) values "
        "(:clerk, 'next_date_set', '{}', false), (:owner, 'next_date_set', '{push}', true)",
        clerk=chamber.users["Ram Clerk"], owner=chamber.owner_id,
    )  # fmt: skip

    record = case_record(
        cnr,
        case_number="1234",
        title="Ramesh Kumar v. State of MP",
        next_hearing_date=date(2026, 10, 28),
        hearings=(HEARD,),
        orders=(FIRST_ORDER,),
        judge="Hon. A",
    )
    assert await apply(record) == ([], [])  # baseline: synced, nobody notified
    [m] = await sql(
        "select court_status, next_hearing_date, judge, court_no, stage, last_order_date, court_fetched_at, title, "
        "case_number, court_id::text, assigned_to::text from public.matters where id = :id",
        id=matter,
    )
    assert m == {
        "court_status": "pending", "next_hearing_date": date(2026, 10, 28), "judge": "Hon. A", "court_no": "12",
        "stage": "Admission", "last_order_date": date(2026, 10, 20), "court_fetched_at": NOW,
        "title": "Ramesh Kumar v. State of MP", "case_number": "1234", "court_id": COURT_MPHC_IND,
        "assigned_to": chamber.users["Ram Clerk"],
    }  # fmt: skip
    [h] = await sql(
        "select id, date, purpose, outcome, next_date, source from public.hearings where matter_id = :m", m=matter
    )
    assert (h["date"], h["outcome"], h["next_date"], h["source"]) == (
        date(2026, 10, 20),
        "Notice issued",
        date(2026, 10, 28),
        "court",
    )
    assert await sql("select title, order_date from public.orders where matter_id = :m", m=matter) == [
        {"title": "order", "order_date": date(2026, 10, 20)}
    ]
    for other in (gone, manual):
        assert await sql("select 1 from public.hearings where matter_id = :m", m=other) == []
        [untouched] = await sql("select court_fetched_at from public.matters where id = :m", m=other)
        assert untouched["court_fetched_at"] is None
    assert await notifications(chamber.id) == []

    await sql("update public.hearings set user_note = 'bring file', confirmed = true where id = :h", h=h["id"])
    second = OrderRef("order-2.pdf", date(2026, 10, 28), "order")
    later_hearing = HearingRecord(date(2026, 10, 28), "Hearing", next_date=date(2026, 11, 5))
    changed = replace(
        record, next_hearing_date=date(2026, 11, 5), orders=(FIRST_ORDER, second), hearings=(HEARD, later_hearing)
    )
    events, to_fetch = await apply(changed)
    [order_id] = [e.court_order_id for e in events if e.kind == "new_order"]
    assert to_fetch == [order_id]
    [kept] = await sql("select user_note, confirmed from public.hearings where id = :h", h=h["id"])
    assert kept == {"user_note": "bring file", "confirmed": True}  # user columns survive a court update

    sent = {(n["who"], n["kind"]): n for n in await notifications(chamber.id)}
    assert {k: n["body"] for k, n in sent.items()} == {
        ("Neha Sharma", "new_order"): "New order in WP 1234/2024.",
        ("Neha Sharma", "next_date_set"): "WP 1234/2024 · Ramesh Kumar v. State of MP: next date Thu 5 Nov.",
        ("Rakesh Jain", "new_order"): "WP 1234/2024 में नया आदेश।",
        ("Rakesh Jain", "next_date_set"): "WP 1234/2024: अगली तारीख गुरु, 5 नवंबर।",
        ("Ram Clerk", "new_order"): "New order in WP 1234/2024.",  # next_date_set is off for the clerk
    }
    assert sent[("Rakesh Jain", "next_date_set")]["title"] == "अगली तारीख"
    assert sent[("Neha Sharma", "next_date_set")]["data"] == {
        "kind": "next_date_set", "org_id": chamber.id, "matter_id": matter, "link": f"/cases/{matter}",
        "event_key": f"{cnr}:next_date_set:2026-11-05", "collapse_key": f"next_date_set:{matter}", "date": "2026-11-05",
    }  # fmt: skip

    async with db.engine().begin() as c:  # a retried fan-out with the same events notifies nobody again
        await fan_out(c, cnr, events)
    assert len(await notifications(chamber.id)) == 5

    disposed = replace(changed, status="disposed")
    await apply(disposed)
    statuses = [n["body"] for n in await notifications(chamber.id) if n["kind"] == "status_changed"]
    assert sorted(statuses) == [
        "WP 1234/2024 marked disposed.",
        "WP 1234/2024 marked disposed.",
        "WP 1234/2024 निराकृत दर्ज किया गया।",
    ]


async def test_a_restored_matter_gets_its_court_rows_back(make: Factory):
    cnr = make.cnr()
    org = await make.org()
    matter = await make.matter(org, cnr)
    await apply(case_record(cnr, hearings=(HEARD,), orders=(FIRST_ORDER,)))
    for table in ("matters", "hearings", "orders"):  # what public.delete_matter does
        column = "id" if table == "matters" else "matter_id"
        await sql(f"update public.{table} set deleted_at = now() where {column} = :m", m=matter)
    await sql("update public.matters set deleted_at = null where id = :m", m=matter)  # found-cases add restores it
    async with db.engine().begin() as c:
        assert await fan_out(c, cnr) == []  # cached CNR: sync only
    assert await sql("select deleted_at from public.hearings where matter_id = :m", m=matter) == [{"deleted_at": None}]
    assert await sql("select deleted_at from public.orders where matter_id = :m", m=matter) == [{"deleted_at": None}]


async def test_a_corrected_sitting_updates_in_place_and_a_withdrawn_one_goes(make: Factory):
    cnr = make.cnr()
    org = await make.org()
    matter = await make.matter(org, cnr)
    unnamed, wrong_day = HearingRecord(date(2026, 10, 20)), HearingRecord(date(2026, 10, 19), "Hearing")
    noted = HearingRecord(date(2026, 10, 18), "Hearing")
    record = case_record(cnr, hearings=(unnamed, wrong_day, noted))
    await apply(record)
    for day, note in (("2026-10-20", "bring file"), ("2026-10-18", "costs paid")):
        await sql("update public.hearings set user_note = :n where matter_id = :m and date = :d",
                  n=note, m=matter, d=date.fromisoformat(day))  # fmt: skip

    # The provider later names the purpose, moves the 19th to the 21st and drops the 18th (which has a user note).
    await apply(replace(record, hearings=(HEARD, HearingRecord(date(2026, 10, 21), "Hearing"))))
    court = await sql("select hearing_date, purpose from public.court_hearings where cnr = :c order by 1", c=cnr)
    assert court == [
        {"hearing_date": date(2026, 10, 20), "purpose": "Admission"},
        {"hearing_date": date(2026, 10, 21), "purpose": "Hearing"},
    ]
    diary = await sql(
        "select date, purpose, user_note, deleted_at is null as live from public.hearings where matter_id = :m "
        "order by date",
        m=matter,
    )
    assert diary == [
        {"date": date(2026, 10, 18), "purpose": "Hearing", "user_note": "costs paid", "live": True},  # kept, detached
        {"date": date(2026, 10, 19), "purpose": "Hearing", "user_note": None, "live": False},
        {"date": date(2026, 10, 20), "purpose": "Admission", "user_note": "bring file", "live": True},
        {"date": date(2026, 10, 21), "purpose": "Hearing", "user_note": None, "live": True},
    ]


async def delete_matter(matter: str) -> None:
    """What public.delete_matter does (the matter, then its hearings), in its own transaction."""
    async with db.engine().begin() as c:
        for table, column in (("matters", "id"), ("hearings", "matter_id")):
            statement = f"update public.{table} set deleted_at = now() where {column} = :m"
            await c.execute(text(statement), {"m": matter})


async def test_a_matter_deleted_during_a_fan_out_keeps_no_live_court_rows(make: Factory):
    cnr = make.cnr()
    org = await make.org()
    matter = await make.matter(org, cnr)
    await apply(case_record(cnr))  # synced; no sittings yet
    await sql("insert into public.court_hearings (cnr, hearing_date) values (:c, '2026-10-20')", c=cnr)

    async with db.engine().begin() as c:
        await fan_out(c, cnr)  # copies the new sitting; the matter row itself is unchanged
        deleting = asyncio.create_task(delete_matter(matter))
        await asyncio.sleep(0.5)
        assert not deleting.done()  # it waits for the fan-out to commit ...
    await deleting
    # ... and then soft-deletes the hearing the fan-out wrote, which it would otherwise not have seen.
    assert await sql("select deleted_at is not null as gone from public.hearings where matter_id = :m", m=matter) == [
        {"gone": True}
    ]


async def test_a_matter_deleted_while_a_sitting_is_withdrawn_does_not_deadlock(make: Factory):
    cnr = make.cnr()
    org = await make.org()
    matter = await make.matter(org, cnr)
    record = case_record(cnr, hearings=(HearingRecord(date(2026, 10, 19)), HEARD))
    await apply(record)

    async with db.engine().begin() as c:
        await apply_case(c, replace(record, hearings=(HEARD,)), NOW)  # withdraws the 19th: its diary hearing goes
        deleting = asyncio.create_task(delete_matter(matter))
        await asyncio.sleep(0.5)
        assert not deleting.done()  # it waits on the matter, not on a hearing this transaction already changed
        await fan_out(c, cnr)
    await deleting
    assert await sql("select deleted_at is not null as gone from public.hearings where matter_id = :m", m=matter) == [
        {"gone": True},
        {"gone": True},
    ]


async def test_board_summary_is_one_message_per_org_and_day(make: Factory):
    org = await make.org("Neha Sharma", members={"Rakesh Jain": ("advocate", "hi")})
    tomorrow = date(2026, 10, 27)
    first, second = await make.matter(org, make.cnr()), await make.matter(org, make.cnr())
    await sql(
        "insert into public.board_entries (org_id, board_date, matter_id, court_id, court_no, item_no, expected_slot) "
        "values (:o, :d, :a, :c, '12', '23', '11:20'), (:o, :d, :b, :c, '7', '5', null)",
        o=org.id, d=tomorrow, a=first, b=second, c=COURT_MPHC_IND,
    )  # fmt: skip
    async with db.engine().begin() as c:
        assert await notify.board_summary(c, "tomorrow_board", org.id, tomorrow) == 2
        assert await notify.board_summary(c, "tomorrow_board", org.id, date(2026, 10, 28)) == 0  # empty board
    later = await make.matter(org, make.cnr())
    await sql(
        "insert into public.board_entries (org_id, board_date, matter_id, court_id, item_no) "
        "values (:o, :d, :m, null, '2024/1234567')",
        o=org.id, d=tomorrow, m=later,
    )  # an item number too long for an int still sorts  # fmt: skip
    async with db.engine().begin() as c:
        assert await notify.board_summary(c, "tomorrow_board", org.id, tomorrow) == 2  # 20:30 rewrites the message
        assert await notify.board_summary(c, "tomorrow_board", org.id, tomorrow) == 0  # 22:00, unchanged: left alone
        await notify.board_summary(c, "today_morning", org.id, tomorrow)
    bodies = {(n["who"], n["kind"]): n["body"] for n in await notifications(org.id)}
    assert bodies == {
        ("Neha Sharma", "today_morning"): "Today: 3 matters. First at MPHC Indore, Court 12, item 23.",
        ("Neha Sharma", "tomorrow_board"): "Tomorrow: 3 matters in 2 courts. First: MPHC Indore, Court 12, item 23.",
        ("Rakesh Jain", "today_morning"): "आज: 3 केस। पहला: MPHC इंदौर, कोर्ट 12, आइटम 23।",
        ("Rakesh Jain", "tomorrow_board"): "कल: 2 कोर्ट में 3 केस। पहला: MPHC इंदौर, कोर्ट 12, आइटम 23।",
    }

    # A later attempt finds the board emptied (the cases moved): the evening's message is taken back.
    await sql("delete from public.board_entries where org_id = :o and board_date = :d", o=org.id, d=tomorrow)
    async with db.engine().begin() as c:
        assert await notify.board_summary(c, "tomorrow_board", org.id, tomorrow) == 0
    assert {n["kind"] for n in await notifications(org.id)} == {"today_morning"}


async def test_sync_issue_and_early_listing(make: Factory):
    org = await make.org(lang="hi")
    cnr = make.cnr()
    matter = await make.matter(org, cnr, case_type="WP", case_number="77", case_year=2025)
    async with db.engine().begin() as c:
        assert await notify.sync_issue(c, org.id, date(2026, 10, 26), time(20, 30)) == 1
        assert await notify.sync_issue(c, org.id, date(2026, 10, 26)) == 0  # once per evening
        [row] = await db.rows(c, "select * from public.matters where id = :m", m=matter)
        where = notify.Position("MPHC Indore", "MPHC इंदौर", "12", "23")
        assert await notify.listed_unexpectedly(c, row, date(2026, 10, 27), where) == 1
        assert await notify.listed_unexpectedly(c, row, date(2026, 10, 27), where) == 0
    assert [n["body"] for n in await notifications(org.id)] == [
        "WP 77/2025 कल सूचीबद्ध है (अपेक्षा से पहले)। MPHC इंदौर, कोर्ट 12, आइटम 23।",
        "कोर्ट डेटा में देरी है। हम रात 8:30 बजे फिर कोशिश करेंगे।",
    ]


def test_labels_and_dates():
    assert notify.case_label({"case_type": "WP", "case_number": "1234", "case_year": 2024}) == "WP 1234/2024"
    assert notify.case_label({"case_type": None, "case_number": "55", "case_year": None, "cnr": "X"}) == "55"
    assert notify.case_label({"case_number": None, "cnr": "MPHC010000012024", "title": "A v. B"}) == "MPHC010000012024"
    assert notify.case_label({"case_number": None, "cnr": "C", "title": "A v. B"}, include_titles=True) == "C · A v. B"
    assert notify.Position("MPHC Indore", "MPHC इंदौर", "7").text("hi") == "MPHC इंदौर, कोर्ट 7"
    assert notify.Position(court_no="7", item_no="S-2").text("en") == "Court 7, item S-2"
    assert notify.day_text(date(2026, 11, 5), "en") == "Thu 5 Nov"
    assert notify.time_text(time(19, 0), "en") == "7 pm"
    assert notify.time_text(time(8, 0), "hi") == "सुबह 8 बजे"
