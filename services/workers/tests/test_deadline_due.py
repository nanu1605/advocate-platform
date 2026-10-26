"""deadline_due reminders (spec §13.1): 3 days, 1 day and on the day before each active deadline, from its
reminder_offsets, counted in IST days; minimum content unless the user includes case titles (§13.2)."""

from datetime import UTC, date, datetime, time, timedelta

from conftest import Factory, sql

from advocate_shared.ist import IST
from advocate_workers.notify import run_deadline_due

TODAY = date(2034, 5, 10)  # a Wednesday far from other tests' dates: the run reads every organisation's deadlines


async def deadline(org_id: str, matter: str | None, due: date, kind: str = "filing", **cols: object) -> str:
    """An active deadline (extra columns as keywords, e.g. status, reminder_offsets, deleted_at)."""
    values = {"status": "active", **cols}
    names = "".join(f", {k}" for k in values)
    marks = "".join(f", :{k}" for k in values)
    [row] = await sql(
        f"insert into public.deadlines (org_id, matter_id, kind, due_date{names}) "
        f"values (:o, :m, :k, :d{marks}) returning id::text",
        o=org_id, m=matter, k=kind, d=due, **values,
    )  # fmt: skip
    return row["id"]


async def reminders(org_id: str) -> list[dict]:
    return await sql(
        "select p.full_name as who, n.title, n.body, n.data from public.notifications n "
        "join public.profiles p on p.id = n.user_id where n.org_id = :o and n.kind = 'deadline_due' "
        "order by (n.data->>'days')::int desc, n.data->>'deadline_id', p.full_name",
        o=org_id,
    )


async def test_three_days_one_day_and_the_day_itself_to_each_member_once(make: Factory):
    org = await make.org(
        "Neha Sharma",
        members={"Rakesh Jain": ("advocate", "hi"), "Ram Clerk": "clerk", "Sita Verma": "junior"},
    )
    clerk, sita = org.users["Ram Clerk"], org.users["Sita Verma"]
    matter = await make.matter(org, make.cnr(), case_type="WP", case_number="1234", case_year=2024, court_no="12",
                               title="Ramesh Kumar v. State of MP")  # fmt: skip
    gone = await make.matter(org, make.cnr(), deleted=True)
    await sql(
        "insert into public.notification_prefs (user_id, kind, channels, include_titles) values "
        "(:owner, 'deadline_due', '{push}', true), (:sita, 'deadline_due', '{}', false), "
        "(:clerk, 'next_date_set', '{push}', true)",
        owner=org.owner_id, sita=sita, clerk=clerk,
    )  # fmt: skip
    in3 = await deadline(org.id, matter, TODAY + timedelta(days=3))
    in1 = await deadline(org.id, matter, TODAY + timedelta(days=1), "limitation")
    today = await deadline(org.id, matter, TODAY, "other")
    week = await deadline(org.id, matter, TODAY + timedelta(days=7), "compliance", reminder_offsets=[7])
    two = await deadline(org.id, matter, TODAY + timedelta(days=2))  # not a reminder day (yet)
    for days in (5, -1):  # not a reminder day, or already past
        await deadline(org.id, matter, TODAY + timedelta(days=days))
    await deadline(org.id, matter, TODAY - timedelta(days=2), reminder_offsets=[-2])  # an offset past the due date
    await deadline(org.id, matter, TODAY + timedelta(days=3), reminder_offsets=[7])  # its own offsets only
    for status in ("done", "dismissed", "proposed"):
        await deadline(org.id, matter, TODAY, status=status)
    await deadline(org.id, matter, TODAY, deleted_at=datetime.now(UTC))
    await deadline(org.id, gone, TODAY)  # the case was deleted
    await deadline(org.id, None, TODAY)  # no case to name or open

    morning = datetime.combine(TODAY, time(7, 30), IST)
    assert await run_deadline_due(morning) == 12  # 4 deadlines x 3 members; Sita turned the kind off
    assert await run_deadline_due(morning) == 0  # the beat firing twice, or a retry, notifies nobody again
    found = await reminders(org.id)
    assert [(r["who"], r["title"], r["body"]) for r in found] == [
        ("Neha Sharma", "Deadline", "WP 1234/2024 · Ramesh Kumar v. State of MP, MPHC Indore, Court 12: compliance due "
                                    "in 7 days (Wed 17 May)."),
        ("Rakesh Jain", "समय-सीमा", "WP 1234/2024, MPHC इंदौर, कोर्ट 12: अनुपालन की आखिरी तारीख 7 दिन में (बुध, 17 मई)।"),
        ("Ram Clerk", "Deadline", "WP 1234/2024, MPHC Indore, Court 12: compliance due in 7 days (Wed 17 May)."),
        ("Neha Sharma", "Deadline", "WP 1234/2024 · Ramesh Kumar v. State of MP, MPHC Indore, Court 12: filing due in "
                                    "3 days (Sat 13 May)."),
        ("Rakesh Jain", "समय-सीमा", "WP 1234/2024, MPHC इंदौर, कोर्ट 12: फ़ाइलिंग की आखिरी तारीख 3 दिन में (शनि, 13 मई)।"),
        ("Ram Clerk", "Deadline", "WP 1234/2024, MPHC Indore, Court 12: filing due in 3 days (Sat 13 May)."),
        ("Neha Sharma", "Deadline", "WP 1234/2024 · Ramesh Kumar v. State of MP, MPHC Indore, Court 12: limitation due "
                                    "tomorrow (Thu 11 May)."),
        ("Rakesh Jain", "समय-सीमा", "WP 1234/2024, MPHC इंदौर, कोर्ट 12: परिसीमा की आखिरी तारीख कल (गुरु, 11 मई)।"),
        ("Ram Clerk", "Deadline", "WP 1234/2024, MPHC Indore, Court 12: limitation due tomorrow (Thu 11 May)."),
        ("Neha Sharma", "Deadline", "WP 1234/2024 · Ramesh Kumar v. State of MP, MPHC Indore, Court 12: deadline due "
                                    "today."),
        ("Rakesh Jain", "समय-सीमा", "WP 1234/2024, MPHC इंदौर, कोर्ट 12: समय-सीमा की आखिरी तारीख आज।"),
        ("Ram Clerk", "Deadline", "WP 1234/2024, MPHC Indore, Court 12: deadline due today."),
    ]  # fmt: skip
    assert [r["data"]["deadline_id"] for r in found[::3]] == [week, in3, in1, today]
    assert found[-1]["data"] == {
        "kind": "deadline_due", "org_id": org.id, "event_key": f"deadline_due:{today}:0", "matter_id": matter,
        "deadline_id": today, "link": f"/cases/{matter}?tab=notes", "collapse_key": f"deadline_due:{today}",
        "due_date": "2034-05-10", "days": 0,
    }  # fmt: skip  # due_date is today: the app lets this one break quiet hours

    # The next morning: the 1-day one is due today and the 2-day one tomorrow; the others are between reminders.
    assert await run_deadline_due(morning + timedelta(days=1)) == 6
    assert {(r["data"]["deadline_id"], r["data"]["days"]) for r in await reminders(org.id)} - {
        (r["data"]["deadline_id"], r["data"]["days"]) for r in found
    } == {(in1, 0), (two, 1)}


async def test_days_are_counted_in_ist(make: Factory):
    org = await make.org("Neha Sharma")
    matter = await make.matter(org, make.cnr(), case_number="7", case_year=2030, court_id=None)
    day = date(2034, 6, 1)
    await deadline(org.id, matter, day, reminder_offsets=[0])
    # 23:59 IST on 31 May: still the day before in India, so not yet the day-of reminder.
    assert await run_deadline_due(datetime(2034, 5, 31, 18, 29, tzinfo=UTC)) == 0
    # 00:00 IST on 1 June, while UTC is still on 31 May.
    assert await run_deadline_due(datetime(2034, 5, 31, 18, 30, tzinfo=UTC)) == 1
    [row] = await reminders(org.id)
    assert (row["body"], row["data"]["due_date"]) == ("7/2030: filing due today.", "2034-06-01")


async def test_a_manual_case_is_named_by_its_file_number_or_else_its_court(make: Factory):
    org = await make.org("Neha Sharma", members={"Rakesh Jain": ("advocate", "hi"), "Ram Clerk": "clerk"})
    await sql(
        "insert into public.notification_prefs (user_id, kind, channels, include_titles) "
        "values (:owner, 'deadline_due', '{push}', true)",
        owner=org.owner_id,
    )
    day = date(2034, 7, 12)  # a Wednesday, away from the test above
    # Manual cases: no number, no CNR; one has the office's file number.
    filed = await make.matter(org, tracking="manual", court_no="12", file_no="F-77", title="Ramesh Kumar v. State")
    bare = await make.matter(org, tracking="manual", court_no="12", title="Sita Devi v. State")
    for matter in (filed, bare):
        await deadline(org.id, matter, day + timedelta(days=3))
    assert await run_deadline_due(datetime.combine(day, time(7, 30), IST)) == 6
    assert {(r["who"], r["body"]) for r in await reminders(org.id)} == {
        ("Neha Sharma", "F-77 · Ramesh Kumar v. State, MPHC Indore, Court 12: filing due in 3 days (Sat 15 Jul)."),
        ("Neha Sharma", "Sita Devi v. State, MPHC Indore, Court 12: filing due in 3 days (Sat 15 Jul)."),
        ("Ram Clerk", "F-77, MPHC Indore, Court 12: filing due in 3 days (Sat 15 Jul)."),
        ("Ram Clerk", "A case at MPHC Indore, Court 12: filing due in 3 days (Sat 15 Jul)."),
        ("Rakesh Jain", "F-77, MPHC इंदौर, कोर्ट 12: फ़ाइलिंग की आखिरी तारीख 3 दिन में (शनि, 15 जुलाई)।"),
        ("Rakesh Jain", "MPHC इंदौर, कोर्ट 12 का एक केस: फ़ाइलिंग की आखिरी तारीख 3 दिन में (शनि, 15 जुलाई)।"),
    }  # fmt: skip
