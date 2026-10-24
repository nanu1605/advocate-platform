"""Find my cases (spec §11.4, §4.1) and the Sunday auto_match (§11.5): groups and progress, call caps, the cause-list
fallback, confidence, merging, decisions that reruns never touch, costs, budgets, outages, cancel and redelivery."""

from datetime import date, timedelta
from decimal import Decimal
from typing import Any

import pytest
from conftest import COURT_DC_IND, COURT_MPHC_IND, COURT_SC, Factory, FakeProvider, Org, random_cnr, sql, unavailable

from advocate_shared.settings import get_settings
from advocate_workers import find, jobs
from advocate_workers.find import plain_name, state_code
from court_data.models import Advocate, CaseHit, CaseSearchQuery, CauseListHit, SearchPage

TODAY = date(2026, 10, 26)  # a Monday: the next 7 court days skip Sunday 1 Nov
NAME = "Neha Sharma"
HC = ("TESTMPHCIND", "TESTMPHCJBP")  # the synthetic codes of the MP courts that have one (Gwalior has none)


def hit(cnr: str, court: str = "TESTMPHCIND", *advocates: str, status: str = "pending") -> CaseHit:
    return CaseHit(
        cnr=cnr, court_code=court, case_type="WP", case_number=cnr[-4:], case_year=2024,
        title="Ramesh Kumar v. State of MP", status=status, next_hearing_date=date(2026, 11, 5),  # type: ignore[arg-type]
        advocates=tuple(Advocate(a, "petitioner") for a in advocates or (NAME,)),
    )  # fmt: skip


def listing(cnr: str, court: str, on: date = TODAY) -> CauseListHit:
    return CauseListHit(cnr, on, court, None, "7", "23", "daily", None, None, None)


async def start(make: Factory, org: Org, **job_input: Any) -> str:
    """A find_cases job as POST /v1/onboarding/find-cases creates it."""
    base = {"advocate_name": NAME, "enrolment_no": "MP/1234/2010", "bar_council_state": "MP", "practice_court_ids": []}
    return await make.job(org, "find_cases", base | job_input)


async def run(job_id: str, today: date = TODAY) -> dict[str, Any]:
    await jobs.run(job_id, lambda job, r: find.run_find_cases(job, r, today))
    [row] = await sql("select status, progress, result, error from public.jobs where id = :id", id=job_id)
    return row


async def found(org: Org) -> dict[str, dict[str, Any]]:
    rows = await sql(
        "select cnr, court_id::text, case_number, court_no, next_date, case_status, confidence, match_reason, source, "
        "decision, job_id::text, user_id::text, title from public.found_cases where org_id = :o",
        o=org.id,
    )
    return {r.pop("cnr"): r for r in rows}


async def add_found(org: Org, cnr: str, decision: str, job_id: str | None = None) -> None:
    """A found_cases row from an earlier search, already decided (or not) by the user."""
    await sql(
        "insert into public.found_cases (org_id, user_id, job_id, cnr, confidence, match_reason, source, decision, "
        "title) values (:o, :u, :j, :c, 'low', 'partial_name', 'onboarding', :d, 'old')",
        o=org.id, u=org.owner_id, j=job_id, c=cnr, d=decision,
    )  # fmt: skip


def searches(provider: FakeProvider) -> list[tuple[str | None, tuple[str, ...], int]]:
    return [(q.advocate, q.court_codes, q.page) for m, q in provider.calls if m == "search_cases"]


def cause_list_days(provider: FakeProvider) -> list[date]:
    return [q.on for m, q in provider.calls if m == "search_cause_list"]


def test_plain_name_drops_honorifics_in_both_scripts():
    assert plain_name("Adv. Neha Sharma") == "Neha Sharma"
    assert plain_name("Shri R.K. Jain") == "R.K. Jain"
    assert plain_name("श्रीमती नेहा शर्मा") == "नेहा शर्मा"
    assert plain_name("Dr. Smt. Asha Verma") == "Asha Verma"
    assert plain_name("डॉ. नेहा शर्मा") == "नेहा शर्मा"
    # Names that sound like an honorific stay: "Dhar" and "Dr" share a phonetic key.
    for name in ("Sanjay Dhar", "Ravi Dar", "Samat Singh", "Mister Lal"):
        assert plain_name(name) == name


def test_state_code_takes_a_code_or_a_name():
    for state in ("MP", "mp", "Madhya Pradesh", " madhya  pradesh ", "मध्य प्रदेश", "मध्यप्रदेश"):
        assert state_code(state) == "MP"
    assert state_code("Kerala") == "KERALA"  # no courts there yet: matches none
    assert state_code(None) is None and state_code(" ") is None


async def test_find_cases_scores_merges_and_reports_per_group(make: Factory, provider: FakeProvider):
    org = await make.org(NAME)
    c = [make.cnr() for _ in range(7)]
    provider.hits = [
        hit(c[0], "TESTMPHCIND", "Adv. Neha Sharma"),  # honorific dropped: exact, in a practice court
        hit(c[1], "TESTMPHCJBP", "N. Sharma"),  # initials: partial
        hit(c[2], "TESTDCIND", "नेहा शर्मा", "R. Sharma"),  # her name in Devanagari: exact
        hit(c[3], "TESTDCIND", status="disposed"),
        hit(c[4], "TESTMPHCIND"),  # already tracked: skipped
        hit(c[5], "TESTMPHCIND"),  # marked "Not mine" before: left alone
    ]
    # Fewer than 10 matters, so the cause lists are searched too: c[0] again (merged), and a Supreme Court
    # listing, which isn't a practice court (no practice courts given, so every MP court is one).
    provider.cause_list = [listing(c[6], "TESTSC"), listing(c[0], "TESTMPHCIND")]
    await make.matter(org, c[4])
    await add_found(org, c[5], "not_mine")

    job_id = await start(make, org)
    row = await run(job_id)
    assert row["status"] == "done"
    assert row["progress"] == {
        "groups": [{"key": "HC", "state": "done", "found": 2}, {"key": "DC", "state": "done", "found": 2}],
        "found": 5,
    }
    assert row["result"] == {"found": 5, "pending": 4, "disposed": 1, "low": 2}

    rows = await found(org)
    assert {cnr: (r["confidence"], r["match_reason"], r["decision"]) for cnr, r in rows.items()} == {
        c[0]: ("high", "exact_name_practice_court", "pending"),
        c[1]: ("low", "partial_name", "pending"),
        c[2]: ("high", "exact_name_practice_court", "pending"),
        c[3]: ("high", "exact_name_practice_court", "pending"),
        c[5]: ("low", "partial_name", "not_mine"),
        c[6]: ("low", "outside_practice_courts", "pending"),
    }
    assert rows[c[5]]["job_id"] is None
    mine = {cnr: r for cnr, r in rows.items() if cnr != c[5]}
    assert {(r["source"], r["job_id"], r["user_id"]) for r in mine.values()} == {("onboarding", job_id, org.owner_id)}
    assert (rows[c[0]]["court_id"], rows[c[0]]["case_number"], rows[c[0]]["next_date"]) == (
        COURT_MPHC_IND, c[0][-4:], date(2026, 11, 5),
    )  # the case search's details win over the listing's  # fmt: skip
    assert (rows[c[3]]["court_id"], rows[c[3]]["case_status"]) == (COURT_DC_IND, "disposed")
    assert {k: rows[c[6]][k] for k in ("court_id", "court_no", "next_date", "case_status", "title")} == {
        "court_id": COURT_SC, "court_no": "7", "next_date": TODAY, "case_status": "pending", "title": None,
    }  # fmt: skip

    assert searches(provider) == [(NAME, HC, 1), (NAME, ("TESTDCIND",), 1)]
    week = [TODAY + timedelta(days=d) for d in (0, 1, 2, 3, 4, 5, 7)]
    assert cause_list_days(provider) == week  # at most 7 calls, court days only
    # In the practice courts: every MP court, so the state (the query takes one court or one state).
    assert {(q.state, q.court_complex_code) for m, q in provider.calls if m == "search_cause_list"} == {("MP", None)}

    costs = await sql(
        "select p.org_id::text, p.operation, p.cost_inr, l.org_id::text as ledger_org from public.provider_calls p "
        "left join public.usage_ledger l on l.ref_id = p.id where p.provider = :p",
        p=provider.name,
    )
    assert len(costs) == 9
    assert {r["org_id"] for r in costs} == {org.id}  # onboarding searches are the organisation's cost
    assert sum(r["cost_inr"] for r in costs) == Decimal("1.40")  # 2 searches + 1 non-empty cause list
    assert {r["ledger_org"] for r in costs if r["cost_inr"]} == {org.id}


async def test_ten_matters_skip_the_cause_lists(make: Factory, provider: FakeProvider):
    org = await make.org(NAME)
    c = [make.cnr() for _ in range(10)]
    provider.hits = [hit(cnr) for cnr in c]
    await make.matter(org, c[0])  # tracked matters count towards the 10
    row = await run(await start(make, org, practice_court_ids=[COURT_MPHC_IND]))
    assert row["progress"] == {"groups": [{"key": "HC", "state": "done", "found": 9}], "found": 9}
    assert searches(provider) == [(NAME, ("TESTMPHCIND",), 1)]
    assert cause_list_days(provider) == []


async def test_a_state_name_finds_its_courts_and_no_courts_fail_the_job(make: Factory, provider: FakeProvider):
    org = await make.org(NAME)
    provider.hits = [hit(make.cnr(), "TESTMPHCIND")]
    row = await run(await start(make, org, bar_council_state="Madhya Pradesh"))  # the onboarding default (§4.1)
    assert (row["status"], row["result"]["found"]) == ("done", 1)
    assert searches(provider)[:2] == [(NAME, HC, 1), (NAME, ("TESTDCIND",), 1)]

    provider.calls.clear()
    row = await run(await start(make, org, bar_council_state="Kerala"))  # no seeded courts
    assert (row["status"], row["error"]) == ("failed", "NO_SEARCHABLE_COURTS")
    gwalior = "c0000000-0000-0000-0000-000000000004"  # a practice court the provider has no code for
    row = await run(await start(make, org, practice_court_ids=[gwalior]))
    assert (row["status"], row["error"]) == ("failed", "NO_SEARCHABLE_COURTS")
    assert provider.calls == []


async def test_searches_stop_at_twenty_shared_by_groups(make: Factory, provider: FakeProvider, monkeypatch):
    org = await make.org(NAME)

    async def endless(q: CaseSearchQuery) -> SearchPage[CaseHit]:
        provider.calls.append(("search_cases", q))
        return SearchPage((hit(random_cnr(), q.court_codes[0]),), 9999, q.page, True)

    monkeypatch.setattr(provider, "search_cases", endless)
    row = await run(await start(make, org))
    assert searches(provider) == [(NAME, HC, p) for p in range(1, 11)] + [
        (NAME, ("TESTDCIND",), p) for p in range(1, 11)
    ]
    assert row["result"]["found"] == 20
    assert cause_list_days(provider) == []


async def test_cancel_mid_run_keeps_what_was_found(make: Factory, provider: FakeProvider, monkeypatch):
    org = await make.org(NAME)
    c = [make.cnr(), make.cnr()]
    provider.hits = [hit(c[0], "TESTMPHCIND"), hit(c[1], "TESTDCIND")]
    search = provider.search_cases
    job_id = await start(make, org)

    async def cancel_then_search(q: CaseSearchQuery) -> SearchPage[CaseHit]:
        await sql("update public.jobs set status = 'cancelled' where id = :id", id=job_id)  # POST .../cancel
        return await search(q)

    monkeypatch.setattr(provider, "search_cases", cancel_then_search)
    row = await run(job_id)
    assert (row["status"], row["result"]) == ("cancelled", None)
    assert row["progress"] == {
        "groups": [{"key": "HC", "state": "running", "found": 0}, {"key": "DC", "state": "pending", "found": 0}],
        "found": 0,
    }  # the last update before the cancel
    assert list(await found(org)) == [c[0]]  # found before the cancel: kept
    assert len(provider.calls) == 1  # nothing after it


async def test_reruns_and_auto_match_never_change_decisions(make: Factory, provider: FakeProvider, r, monkeypatch):
    org = await make.org(NAME, members={"Amit Jain": "advocate", "Ravi Verma": "junior"})
    c = [make.cnr() for _ in range(6)]
    for cnr, decision in zip(c, ("not_mine", "skipped", "added", "pending"), strict=False):
        await add_found(org, cnr, decision)
    provider.hits = [hit(cnr) for cnr in c[:5]]

    job_id = await start(make, org, practice_court_ids=[COURT_MPHC_IND])
    assert (await run(job_id))["result"] == {"found": 2, "pending": 2, "disposed": 0, "low": 0}
    rows = await found(org)
    decided = {
        (rows[cnr]["decision"], rows[cnr]["confidence"], rows[cnr]["job_id"], rows[cnr]["title"]) for cnr in c[:3]
    }
    assert decided == {("not_mine", "low", None, "old"), ("skipped", "low", None, "old"), ("added", "low", None, "old")}
    refreshed = rows[c[3]]  # still pending: refreshed like a new row
    assert (refreshed["confidence"], refreshed["job_id"], refreshed["title"]) == ("high", job_id, rows[c[4]]["title"])

    # Sunday auto_match, for this organisation only: the owner (practice courts from the Bar Council state) and the
    # advocate member (Supreme Court only) are searched, the junior isn't. Existing rows stay exactly as they are.
    await sql("update public.profiles set bar_council_state = 'MP' where id = :u", u=org.owner_id)
    await sql("update public.profiles set practice_court_ids = array[cast(:c as uuid)] where id = :u",
              c=COURT_SC, u=org.users["Amit Jain"])  # fmt: skip
    provider.hits.append(hit(c[5], "TESTSC", "Amit Jain"))
    provider.calls.clear()
    everyone = find.advocates

    async def ours() -> list[dict[str, Any]]:
        return [a for a in await everyone() if a["org_id"] == org.id]

    monkeypatch.setattr(find, "advocates", ours)
    before = await found(org)
    sunday = date(2031, 3, 9)  # the run lock is per day: keep this test's apart
    try:
        assert await find.run_auto_match(r, sunday) == {"advocates": 2, "found": 1}
        assert await find.run_auto_match(r, sunday) == {"advocates": 0, "found": 0}  # a second beat tick: no-op
    finally:
        await r.delete(f"sched:auto_match:{sunday}")
    assert searches(provider) == [(NAME, HC, 1), (NAME, ("TESTDCIND",), 1), ("Amit Jain", ("TESTSC",), 1)]
    after = await found(org)
    assert {cnr: after[cnr] for cnr in before} == before
    assert {k: after[c[5]][k] for k in ("source", "job_id", "user_id", "confidence", "court_id")} == {
        "source": "auto_match", "job_id": None, "user_id": org.users["Amit Jain"], "confidence": "high",
        "court_id": COURT_SC,
    }  # fmt: skip
    org_costs = await sql(
        "select distinct org_id::text from public.provider_calls where provider = :p", p=provider.name
    )
    assert org_costs == [{"org_id": org.id}]


@pytest.mark.parametrize("budget", ["global", "org"])
async def test_budgets_pause_the_job(make: Factory, provider: FakeProvider, r, monkeypatch, budget: str):
    org = await make.org(NAME)
    c = [make.cnr(), make.cnr()]
    provider.hits = [hit(c[0], "TESTMPHCIND"), hit(c[1], "TESTDCIND")]
    day = date(2031, 3, 10)  # the once-a-day budget alert keys: keep this test's apart
    s = get_settings()
    if budget == "global":
        monkeypatch.setattr(s, "courtdata_global_daily_cap_inr", Decimal(0))  # reached, whatever others spend
    else:
        monkeypatch.setattr(s, "courtdata_org_monthly_default_inr", Decimal("0.20"))  # one search's worth
    try:
        row = await run(await start(make, org), day)
    finally:
        await r.delete(
            *(f"budget-alert:{scope}:{pct}:{day}" for scope in ("global", f"org:{org.id}") for pct in (80, 100))
        )
    assert row["status"] == "failed"
    if budget == "global":
        assert row["error"] == "COURT_DATA_PAUSED"
        assert provider.calls == []
        assert await found(org) == {}
    else:
        assert row["error"] == "COURT_DATA_BUDGET_REACHED"  # checked again before the second search
        assert searches(provider) == [(NAME, HC, 1)]
        assert list(await found(org)) == [c[0]]  # kept


async def test_provider_down_fails_the_job_unless_some_search_worked(make: Factory, provider: FakeProvider):
    org = await make.org(NAME)
    provider.fail = {"search_cases": unavailable(), "search_cause_list": unavailable()}
    row = await run(await start(make, org))
    assert (row["status"], row["error"]) == ("failed", "COURT_PROVIDER_UNAVAILABLE")
    assert [g["state"] for g in row["progress"]["groups"]] == ["failed", "failed"]
    assert row["result"] == {"found": 0, "pending": 0, "disposed": 0, "low": 0}

    cnr = make.cnr()
    provider.hits = [hit(cnr, "TESTDCIND")]
    provider.fail = {"search_cases": [unavailable()]}  # only the High Court search fails
    row = await run(await start(make, org))
    assert (row["status"], row["result"]["found"]) == ("done", 1)
    assert row["progress"]["groups"] == [
        {"key": "HC", "state": "failed", "found": 0},
        {"key": "DC", "state": "done", "found": 1},
    ]


async def test_redelivered_job_resumes_then_no_ops(make: Factory, provider: FakeProvider):
    org = await make.org(NAME)
    c = [make.cnr() for _ in range(3)]
    provider.hits = [hit(c[0], "TESTMPHCIND"), hit(c[1], "TESTMPHCIND"), hit(c[2], "TESTDCIND")]
    job_id = await start(make, org)
    # An earlier run finished the High Court group (finding c[0]) and died: the job is still running.
    await add_found(org, c[0], "pending", job_id)
    await sql(
        "update public.jobs set status = 'running', progress = cast(:p as jsonb) where id = :id",
        p='{"groups": [{"key": "HC", "state": "done", "found": 1}], "found": 1}', id=job_id,
    )  # fmt: skip
    row = await run(job_id)
    assert row["status"] == "done"
    assert row["progress"] == {
        "groups": [{"key": "HC", "state": "done", "found": 1}, {"key": "DC", "state": "done", "found": 1}],
        "found": 2,
    }
    assert searches(provider) == [(NAME, ("TESTDCIND",), 1)]  # the High Court isn't searched again
    assert sorted(await found(org)) == sorted([c[0], c[2]])
    calls = len(provider.calls)
    assert (await run(job_id))["status"] == "done"  # redelivered once done: nothing runs
    assert len(provider.calls) == calls
