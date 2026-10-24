"""Case refreshes (spec §11.5, §11.6, §11.8): the fetch_cases and refresh_case jobs, the post-hearing refresh and its
retries, the weekly sweep, and the budget rules each runs under."""

from dataclasses import replace
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from typing import Any

import pytest
from conftest import Factory, FakeProvider, case_record, random_cnr, sql, unavailable

from advocate_shared import tasks
from advocate_shared.ist import IST
from advocate_shared.settings import get_settings
from advocate_workers import celery_app, jobs, refresh
from advocate_workers.courts import Spend
from court_data.models import HearingRecord, OrderRef, ProviderError

NOW = datetime(2026, 10, 26, 19, 30, tzinfo=IST)
HEARING = HearingRecord(date(2026, 10, 12), "Admission", next_date=date(2026, 10, 26))
ORDER = OrderRef("order-1.pdf", date(2026, 10, 12), "order")


def run(body, now: datetime = NOW):
    return lambda job, r: body(job, r, now)


async def job_row(job_id: str) -> dict[str, Any]:
    [row] = await sql("select status, progress, result, error from public.jobs where id = :id", id=job_id)
    return row


async def notifications(org_id: str) -> list[dict[str, Any]]:
    return await sql(
        "select kind, data->>'event_key' as key from public.notifications where org_id = :o order by kind", o=org_id
    )


async def costs(provider: FakeProvider) -> list[tuple]:
    found = await sql(
        "select org_id::text, operation, cost_inr from public.provider_calls where provider = :p", p=provider.name
    )
    return sorted((r["org_id"] or "", r["operation"], r["cost_inr"]) for r in found)


async def recording_sleep(monkeypatch: pytest.MonkeyPatch) -> list[float]:
    waits: list[float] = []

    async def fake(seconds: float) -> None:
        waits.append(seconds)

    monkeypatch.setattr(refresh, "sleep", fake)
    return waits


def test_tasks_are_registered_under_their_names():
    for name in (tasks.FETCH_CASES, tasks.REFRESH_CASE, celery_app.POST_HEARING_REFRESH, celery_app.WEEKLY_SWEEP):
        assert name in celery_app.app.tasks
    assert celery_app.POST_HEARING_RETRY in celery_app.app.tasks


async def test_fetch_cases_fetches_new_cases_and_reuses_fresh_ones(make: Factory, provider: FakeProvider, sent):
    org = await make.org()
    new, cached, old, unknown = make.cnr(), make.cnr(), make.cnr(), make.cnr()
    provider.add(case_record(new, next_hearing_date=date(2026, 11, 2), hearings=(HEARING,), orders=(ORDER,)))
    for cnr, age in ((cached, timedelta(hours=5)), (old, timedelta(hours=7))):
        await refresh.store(provider.add(case_record(cnr)), NOW - age)  # fetched earlier for someone else
    ids = [await make.matter(org, cnr) for cnr in (new, cached, old, unknown)]
    manual = await make.matter(org, make.cnr(), tracking="manual")
    deleted = await make.matter(org, make.cnr(), deleted=True)
    job = await make.job(org, "fetch_cases", {"matter_ids": [*ids, manual, deleted]})

    await jobs.run(job, run(refresh.fetch))
    assert provider.calls == [("get_case", new), ("get_case", old), ("get_case", unknown)]
    row = await job_row(job)
    assert (row["status"], row["result"]) == ("done", {"done": 6, "total": 6, "not_found": [ids[3]], "failed": []})
    assert await costs(provider) == [(org.id, "case_detail", 0), *[(org.id, "case_detail", Decimal("0.5"))] * 2]

    # The first fetch of a CNR is the baseline: synced, but no events, so no notification and no PDF fetch.
    [m] = await sql("select next_hearing_date, court_fetched_at from public.matters where id = :m", m=ids[0])
    assert m == {"next_hearing_date": date(2026, 11, 2), "court_fetched_at": NOW}
    for table in ("hearings", "orders"):
        assert len(await sql(f"select 1 from public.{table} where matter_id = :m", m=ids[0])) == 1
    assert sent == [] and await notifications(org.id) == []
    [m] = await sql("select court_fetched_at from public.matters where id = :m", m=ids[1])
    assert m["court_fetched_at"] == NOW - timedelta(hours=5)  # synced from the cache


async def test_fetch_cases_retries_resumes_and_stops_when_cancelled(make: Factory, provider: FakeProvider, r):
    org = await make.org()
    first, second = make.cnr(), make.cnr()
    ids = []
    for cnr in (first, second):
        provider.add(case_record(cnr))
        ids.append(await make.matter(org, cnr))
    provider.fail["get_case"] = [None, unavailable()]
    job = await make.job(org, "fetch_cases", {"matter_ids": ids})
    with pytest.raises(jobs.RetryLater):
        await jobs.run(job, run(refresh.fetch))
    assert (await job_row(job))["progress"] == {"done": 1, "total": 2, "not_found": [], "failed": []}

    later = NOW + timedelta(hours=7)  # the first case's record is no longer fresh, yet it isn't fetched again
    await jobs.run(job, run(refresh.fetch, later))
    assert provider.calls == [("get_case", first), ("get_case", second), ("get_case", second)]
    assert (await job_row(job))["status"] == "done"

    provider.calls.clear()
    cancelled = await make.job(org, "fetch_cases", {"matter_ids": ids}, status="cancelled")
    claimed = jobs.Job(cancelled, org.id, org.owner_id, "fetch_cases", {"matter_ids": ids}, {}, None)
    assert await refresh.fetch(claimed, r, later + timedelta(hours=7)) is None
    assert provider.calls == [("get_case", first)]  # stopped after the first matter


async def test_fetch_cases_reports_a_rejected_cnr_and_fetches_the_rest(make: Factory, provider: FakeProvider):
    org = await make.org()
    rejected, fine = make.cnr(), make.cnr()
    provider.add(case_record(fine))
    ids = [await make.matter(org, cnr) for cnr in (rejected, fine)]
    provider.fail["get_case"] = [ProviderError("HTTP_400", "unsupported court", http_status=400)]
    job = await make.job(org, "fetch_cases", {"matter_ids": ids})
    await jobs.run(job, run(refresh.fetch))
    row = await job_row(job)
    assert (row["status"], row["result"]) == (
        "done",
        {"done": 2, "total": 2, "not_found": [], "failed": [{"matter_id": ids[0], "code": "HTTP_400"}]},
    )
    assert provider.calls == [("get_case", rejected), ("get_case", fine)]


async def test_changes_notify_once_and_user_fields_survive(make: Factory, provider: FakeProvider, r, sent):
    org = await make.org()
    cnr = make.cnr()
    matter = await make.matter(org, cnr)
    heard = date(2026, 10, 26)
    record = provider.add(case_record(cnr, next_hearing_date=heard, hearings=(HEARING,), orders=(ORDER,)))
    await refresh.store(record, NOW - timedelta(days=14))
    await sql(
        "update public.hearings set user_note = 'bring file', user_next_date = '2026-11-14', confirmed = true "
        "where matter_id = :m",
        m=matter,
    )

    later_hearing = HearingRecord(heard, "Hearing", next_date=date(2026, 11, 12))
    second = OrderRef("order-2.pdf", heard, "interim")
    provider.add(replace(record, next_hearing_date=date(2026, 11, 12), last_hearing_date=heard,
                         hearings=(HEARING, later_hearing), orders=(ORDER, second)))  # fmt: skip
    assert await refresh.refresh_cnrs(r, Spend.PROTECTED, [cnr], NOW) == {"cnrs": 1, "fetched": 1, "events": 2}
    [new_order] = await sql(
        "select id::text from public.court_orders where cnr = :c and provider_ref = 'order-2.pdf'", c=cnr
    )
    assert sent == [(celery_app.ORDER_PIPELINE, (new_order["id"],))]
    assert [n["key"] for n in await notifications(org.id)] == [
        f"{cnr}:new_order:order-2.pdf",
        f"{cnr}:next_date_set:2026-11-12",
    ]

    await refresh.refresh_cnrs(r, Spend.PLATFORM, [cnr], NOW + timedelta(hours=12))  # a retry finds the same record
    assert len(sent) == 1 and len(await notifications(org.id)) == 2

    provider.add(replace(provider.cases[cnr], status="disposed", next_hearing_date=None, decision_date=heard))
    for i, events in enumerate([["status_changed"], []]):  # the second on-demand refresh changes nothing
        job = await make.job(org, "refresh_case", {"matter_id": matter})
        await jobs.run(job, run(refresh.refresh, NOW + timedelta(days=1, hours=i)))
        assert (await job_row(job))["result"] == {"refreshed": True, "cached": False, "events": events}
    assert [n["kind"] for n in await notifications(org.id)] == ["new_order", "next_date_set", "status_changed"]
    assert await sql(
        "select user_note, user_next_date, confirmed from public.hearings where matter_id = :m and date = :d",
        m=matter, d=HEARING.hearing_date,
    ) == [{"user_note": "bring file", "user_next_date": date(2026, 11, 14), "confirmed": True}]  # fmt: skip
    assert len(await sql("select 1 from public.hearings where matter_id = :m", m=matter)) == 2


async def test_a_restored_matter_gets_its_court_rows_back(make: Factory, provider: FakeProvider):
    org = await make.org()
    cnr = make.cnr()
    matter = await make.matter(org, cnr)
    await refresh.store(provider.add(case_record(cnr, hearings=(HEARING,), orders=(ORDER,))), NOW - timedelta(hours=1))
    for table, column in (("matters", "id"), ("hearings", "matter_id"), ("orders", "matter_id")):  # delete_matter
        await sql(f"update public.{table} set deleted_at = now() where {column} = :m", m=matter)
    await sql("update public.matters set deleted_at = null where id = :m", m=matter)  # re-added from found cases
    job = await make.job(org, "fetch_cases", {"matter_ids": [matter]})
    await jobs.run(job, run(refresh.fetch))
    assert provider.calls == []  # the court record is under 6 h old
    for table in ("hearings", "orders"):
        assert await sql(f"select deleted_at from public.{table} where matter_id = :m", m=matter) == [
            {"deleted_at": None}
        ]


async def test_refresh_case_reuses_a_fresh_record_and_waits_for_the_provider(
    make: Factory, provider: FakeProvider, monkeypatch
):
    waits = await recording_sleep(monkeypatch)
    org = await make.org()
    cnr = make.cnr()
    matter = await make.matter(org, cnr)
    await refresh.store(provider.add(case_record(cnr)), NOW - timedelta(minutes=10))
    job = await make.job(org, "refresh_case", {"matter_id": matter})
    await jobs.run(job, run(refresh.refresh))
    assert (await job_row(job))["result"] == {"refreshed": True, "cached": True, "events": []}
    assert provider.calls == []

    provider.ready_in_s = 90
    later = NOW + timedelta(minutes=10)  # the record is now 20 minutes old
    job = await make.job(org, "refresh_case", {"matter_id": matter})
    await jobs.run(job, run(refresh.refresh, later))
    assert provider.calls == [("refresh_case", cnr), ("get_case", cnr)]
    assert waits == [refresh.MAX_WAIT_S]
    [m] = await sql("select court_fetched_at from public.matters where id = :m", m=matter)
    assert m["court_fetched_at"] == later
    assert await costs(provider) == [(org.id, "case_detail", Decimal("0.5")), (org.id, "refresh", Decimal("0.05"))]

    manual = await make.matter(org, make.cnr(), tracking="manual")
    deleted = await make.matter(org, make.cnr(), deleted=True)
    for nothing_to_do in (manual, deleted):
        job = await make.job(org, "refresh_case", {"matter_id": nothing_to_do})
        await jobs.run(job, run(refresh.refresh))
        assert (await job_row(job))["result"] == {"refreshed": False}
    unknown = await make.matter(org, make.cnr())
    job = await make.job(org, "refresh_case", {"matter_id": unknown})
    await jobs.run(job, run(refresh.refresh))
    assert (await job_row(job))["error"] == "CASE_NOT_FOUND"


async def test_bulk_refresh_goes_in_chunks_of_50(make: Factory, provider: FakeProvider, r, monkeypatch):
    waits = await recording_sleep(monkeypatch)
    known = [make.cnr() for _ in range(3)]
    for cnr in known:
        provider.add(case_record(cnr))
    cnrs = sorted([*known, *(random_cnr() for _ in range(117))])  # the rest are CNRs the provider rejects
    provider.ready_in_s = 30
    provider.fail["get_case"] = [unavailable()]
    assert await refresh.refresh_cnrs(r, Spend.PLATFORM, cnrs, NOW) == {"cnrs": 120, "fetched": 2, "events": 0}
    bulk = [arg for method, arg in provider.calls if method == "bulk_refresh"]
    assert [len(chunk) for chunk in bulk] == [50, 50, 20]
    assert [cnr for chunk in bulk for cnr in chunk] == cnrs
    assert sorted(arg for method, arg in provider.calls if method == "get_case") == sorted(known)  # 1 failed, skipped
    assert waits == [30]  # once, for the slowest ticket
    assert [c for c in await costs(provider) if c[1] == "bulk_refresh"] == [
        ("", "bulk_refresh", Decimal("1.00")),
        ("", "bulk_refresh", Decimal("2.50")),
        ("", "bulk_refresh", Decimal("2.50")),
    ]  # platform rows

    provider.calls.clear()
    provider.changed = False  # a provider that says nothing changed: no case detail fetched
    await refresh.refresh_cnrs(r, Spend.PLATFORM, cnrs, NOW)
    assert [method for method, _ in provider.calls] == ["bulk_refresh"] * 3


async def test_post_hearing_sets(make: Factory):
    day = date(2031, 2, 4)
    org = await make.org()

    async def case(tracking: str = "auto", listed: bool = False, **fields: Any) -> str:
        cnr = make.cnr()
        await make.matter(org, cnr, tracking=tracking)
        await refresh.store(case_record(cnr, **fields), NOW)
        if listed:
            await sql("insert into public.cause_list_entries (cnr, list_date) values (:c, :d)", c=cnr, d=day)
        return cnr

    waiting = await case(next_hearing_date=day, last_hearing_date=date(2031, 1, 7))
    listed = await case(listed=True)  # no next date on record, but on that day's cause list
    updated = await case(listed=True, next_hearing_date=date(2031, 3, 1), last_hearing_date=day)
    disposed = await case(next_hearing_date=day, status="disposed")
    unknown = await case(next_hearing_date=day, status="unknown")  # a status the provider didn't name
    manual = await case(tracking="manual", next_hearing_date=day)
    next_day = await case(next_hearing_date=day + timedelta(days=1))
    never = make.cnr()  # listed, but its court record was never fetched
    await make.matter(org, never)
    await sql("insert into public.cause_list_entries (cnr, list_date) values (:c, :d)", c=never, d=day)
    mine = {waiting, listed, updated, disposed, unknown, manual, next_day, never}
    assert set(await refresh.heard(day)) & mine == {waiting, listed, updated, disposed, unknown, never}
    assert set(await refresh.heard(day, not_updated=True)) & mine == {waiting, listed, unknown, never}  # retries


async def test_the_second_retry_leaves_cases_heard_again_today_to_post_hearing_refresh(
    make: Factory, provider: FakeProvider, r
):
    day = date(2031, 5, 13)
    now = datetime.combine(day + timedelta(days=1), time(19, 30), IST)
    org = await make.org()
    again, once = make.cnr(), make.cnr()
    for cnr in (again, once):  # heard on `day`, and the court record shows no update since
        await make.matter(org, cnr)
        await refresh.store(provider.add(case_record(cnr)), now - timedelta(days=3))
        await sql("insert into public.cause_list_entries (cnr, list_date) values (:c, :d)", c=cnr, d=day)
    await sql("insert into public.cause_list_entries (cnr, list_date) values (:c, :d)", c=again, d=now.date())
    keys = [f"sched:post_hearing_retry:{now.date()}:{attempt}" for attempt in (1, 2)]
    try:
        await refresh.retry(r, now, 2)  # `again` was not reached and is listed today: post_hearing_refresh's
        assert [arg for method, arg in provider.calls if method == "bulk_refresh"] == [[once]]
        provider.calls.clear()
        await refresh.retry(r, now, 1)
        assert [arg for method, arg in provider.calls if method == "bulk_refresh"] == [sorted([again, once])]
    finally:
        await r.delete(*keys)


async def test_weekly_sweep_takes_stale_cases_fortnightly(make: Factory, provider: FakeProvider, r):
    now = datetime(2031, 2, 9, 10, 0, tzinfo=IST)  # a Sunday
    org = await make.org()

    async def case(age_days: int, **fields: Any) -> str:
        cnr = make.cnr()
        await make.matter(org, cnr)
        await refresh.store(provider.add(case_record(cnr, **fields)), now - timedelta(days=age_days))
        return cnr

    no_date = await case(14)
    recent = await case(12)
    past = await case(14, next_hearing_date=date(2031, 1, 20))
    upcoming = await case(30, next_hearing_date=date(2031, 2, 20))
    disposed = await case(30, status="disposed")
    unknown = await case(14, status="unknown")
    never = make.cnr()  # its import never fetched it (e.g. paused at the budget)
    await make.matter(org, never)
    provider.add(case_record(never))
    mine = {no_date, recent, past, upcoming, disposed, unknown, never}
    assert set(await refresh.stale(now)) & mine == {no_date, past, unknown, never}

    key = f"sched:weekly_sweep:{now.date()}"
    try:
        assert (await refresh.sweep(r, now) or {})["fetched"] == 4
        assert await refresh.sweep(r, now) is None  # once per Sunday
    finally:
        await r.delete(key)
    assert {arg for method, arg in provider.calls if method == "get_case"} == {no_date, past, unknown, never}
    [m] = await sql("select court_fetched_at from public.matters where cnr = :c", c=never)
    assert m["court_fetched_at"] == now


async def test_scheduled_refreshes_pick_their_day_and_budgets_pause_all_but_the_first(
    make: Factory, provider: FakeProvider, r, monkeypatch
):
    day = date(2031, 3, 4)
    at, next_day = datetime.combine(day, time(19, 30), IST), datetime.combine(day + timedelta(days=1), time(8), IST)
    org = await make.org()
    cnr, tomorrow_cnr = make.cnr(), make.cnr()
    matter = await make.matter(org, cnr)
    await make.matter(org, tomorrow_cnr)
    await refresh.store(provider.add(case_record(cnr, next_hearing_date=day)), at - timedelta(days=1))
    await refresh.store(provider.add(case_record(tomorrow_cnr, next_hearing_date=next_day.date())), at)
    settings = get_settings()
    monkeypatch.setattr(settings, "courtdata_global_daily_cap_inr", Decimal(0))  # reached, whatever others spend
    keys = [f"sched:post_hearing_refresh:{day}", *(f"sched:post_hearing_retry:{next_day.date()}:{a}" for a in (1, 2))]
    keys += [f"budget-alert:{s}:{level}:{d}" for s in ("global", f"org:{org.id}") for level in (80, 100)
             for d in (day, next_day.date())]  # fmt: skip
    try:
        assert await refresh.post_hearing(r, at) == {"cnrs": 1, "fetched": 1, "events": 0}  # PROTECTED
        assert await refresh.post_hearing(r, at) is None  # once a day
        assert provider.calls == [("bulk_refresh", [cnr]), ("get_case", cnr)]
        for attempt in (1, 2):  # the record still shows no hearing on `day`, but the global cap pauses retries
            assert (await refresh.retry(r, next_day, attempt) or {})["paused"] == "COURT_DATA_PAUSED"
        job = await make.job(org, "refresh_case", {"matter_id": matter})
        await jobs.run(job, run(refresh.refresh, next_day))
        assert (await job_row(job))["error"] == "COURT_DATA_PAUSED"
        assert len(provider.calls) == 2

        monkeypatch.setattr(settings, "courtdata_global_daily_cap_inr", None)
        monkeypatch.setattr(settings, "courtdata_org_monthly_default_inr", Decimal("0.10"))
        await sql(
            "insert into public.provider_calls (provider, operation, org_id, cost_inr, status) "
            "values (:p, 'search', :o, 1, 'ok')",
            p=provider.name, o=org.id,
        )  # fmt: skip
        await r.delete(*keys[1:3])
        provider.calls.clear()
        assert await refresh.retry(r, next_day, 2) == {"cnrs": 1, "fetched": 0, "events": 0}  # its only org is over
        assert provider.calls == []
        assert await refresh.retry(r, next_day, 1) == {"cnrs": 1, "fetched": 1, "events": 0}  # global cap only
        job = await make.job(org, "refresh_case", {"matter_id": matter})
        await jobs.run(job, run(refresh.refresh, next_day))
        assert (await job_row(job))["error"] == "COURT_DATA_BUDGET_REACHED"
        assert [method for method, _ in provider.calls] == ["bulk_refresh", "get_case"]
    finally:
        await r.delete(*keys)
