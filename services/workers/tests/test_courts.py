"""Court data for workers: cost records (org vs platform rows), the §11.8 budget rules, court codes, court days."""

from datetime import date
from decimal import Decimal
from uuid import UUID

import pytest
from conftest import COURT_DC_IND, COURT_MPHC_IND, Factory, FakeProvider, case_record, sql, unavailable
from structlog.testing import capture_logs

from advocate_shared.settings import get_settings
from advocate_workers import db
from advocate_workers.courts import CourtData, Paused, Spend, court_codes, court_days, court_ids
from court_data.models import Capability, CourtDataProvider

TODAY = date(2026, 10, 26)


def get_case(cnr: str):
    async def call(p: CourtDataProvider):
        return await p.get_case(cnr)

    return call


async def costs(provider: FakeProvider) -> list[dict]:
    return await sql(
        "select p.org_id::text, p.cnr, p.status, p.cost_inr, l.org_id::text as ledger_org, l.cost_inr as ledger_cost "
        "from public.provider_calls p left join public.usage_ledger l on l.ref_id = p.id "
        "where p.provider = :p order by p.created_at",
        p=provider.name,
    )


async def test_calls_are_costed_to_the_org_or_the_platform(make: Factory, provider: FakeProvider, r):
    org = await make.org()
    cnr = make.cnr()
    provider.add(case_record(cnr))
    async with CourtData(r, TODAY) as cd:
        assert (await cd.call(Spend.ORG, Capability.CASE_DETAIL, get_case(cnr), org_id=org.id, cnr=cnr)).cnr == cnr
        await cd.call(Spend.PROTECTED, Capability.CASE_DETAIL, get_case(cnr), cnr=cnr)
        provider.fail["get_case"] = unavailable()
        with pytest.raises(Exception, match="down"):
            await cd.call(Spend.PLATFORM, Capability.CASE_DETAIL, get_case(cnr), cnr=cnr)
    half = Decimal("0.5")
    assert await costs(provider) == [
        {"org_id": org.id, "cnr": cnr, "status": "ok", "cost_inr": half, "ledger_org": org.id, "ledger_cost": half},
        {"org_id": None, "cnr": cnr, "status": "ok", "cost_inr": half, "ledger_org": None, "ledger_cost": half},
        {"org_id": None, "cnr": cnr, "status": "COURT_PROVIDER_UNAVAILABLE", "cost_inr": 0, "ledger_org": None,
         "ledger_cost": None},
    ]  # fmt: skip
    with pytest.raises(ValueError, match="org_id"):
        await cd.call(Spend.ORG, Capability.CASE_DETAIL, get_case(cnr))


async def test_global_cap_pauses_everything_but_protected_jobs(make: Factory, provider: FakeProvider, r, monkeypatch):
    cnr = make.cnr()
    provider.add(case_record(cnr))
    monkeypatch.setattr(get_settings(), "courtdata_global_daily_cap_inr", Decimal(0))  # reached, whatever others spend
    alert_day = date(2031, 3, 3)  # the once-a-day global alert key is shared: keep this test's apart
    try:
        async with CourtData(r, alert_day) as cd:
            for spend in (Spend.ORG, Spend.PLATFORM, Spend.SHARED):
                with pytest.raises(Paused) as paused:
                    await cd.call(
                        spend, Capability.CASE_DETAIL, get_case(cnr), org_id="00000000-0000-0000-0000-000000000000"
                    )
                assert paused.value.code == "COURT_DATA_PAUSED"
            assert provider.calls == []
            await cd.call(Spend.PROTECTED, Capability.CASE_DETAIL, get_case(cnr), cnr=cnr)
        assert provider.calls == [("get_case", cnr)]
    finally:
        await r.delete(f"budget-alert:global:100:{alert_day}")

    monkeypatch.setattr(get_settings(), "courtdata_global_daily_cap_inr", Decimal(10**9))  # far from reached
    async with CourtData(r, TODAY) as cd:
        await cd.call(Spend.PLATFORM, Capability.CASE_DETAIL, get_case(cnr), cnr=cnr)


async def test_org_budget_pauses_org_jobs_and_alerts_once(make: Factory, provider: FakeProvider, r, monkeypatch):
    org = await make.org()
    cnr = make.cnr()
    provider.add(case_record(cnr))
    monkeypatch.setattr(get_settings(), "courtdata_org_monthly_default_inr", Decimal("0.55"))
    keys = [f"budget-alert:org:{org.id}:{level}:{TODAY}" for level in (80, 100)]
    try:
        with capture_logs() as logs:
            async with CourtData(r, TODAY) as cd:
                await cd.call(Spend.ORG, Capability.CASE_DETAIL, get_case(cnr), org_id=org.id)  # ₹0.50 of ₹0.55
                await cd.call(Spend.ORG, Capability.REFRESH, lambda p: p.refresh_case(cnr), org_id=org.id)  # ₹0.55
                for _ in range(2):
                    with pytest.raises(Paused) as paused:
                        await cd.call(Spend.ORG, Capability.CASE_DETAIL, get_case(cnr), org_id=org.id)
                    assert paused.value.code == "COURT_DATA_BUDGET_REACHED"
                await cd.call(Spend.PLATFORM, Capability.CASE_DETAIL, get_case(cnr), cnr=cnr)  # platform rows go on
        alerts = [(e["log_level"], e["percent"]) for e in logs if e.get("scope") == f"org:{org.id}"]
        assert alerts == [("warning", 80), ("error", 100)]  # 80% before the refresh, 100% once, not per check
    finally:
        await r.delete(*keys)


async def test_shared_fetches_skip_cnrs_whose_orgs_are_all_over_budget(
    make: Factory, provider: FakeProvider, r, monkeypatch
):
    spent_org, fresh_org = await make.org(), await make.org("Arun Mehta")
    only_spent, both, untracked = make.cnr(), make.cnr(), make.cnr()
    await make.matter(spent_org, only_spent)
    await make.matter(spent_org, both)
    await make.matter(fresh_org, both)
    provider.add(case_record(only_spent))
    async with CourtData(r, TODAY) as cd:
        assert await cd.drop_over_budget([only_spent, both, untracked]) == [only_spent, both, untracked]  # no budget
        await cd.call(Spend.ORG, Capability.CASE_DETAIL, get_case(only_spent), org_id=spent_org.id)
        monkeypatch.setattr(get_settings(), "courtdata_org_monthly_default_inr", Decimal("0.10"))
        assert await cd.drop_over_budget([only_spent, both, untracked]) == [both]


async def test_court_codes_map_both_ways(make: Factory, provider: FakeProvider, monkeypatch):
    gwalior = UUID("c0000000-0000-0000-0000-000000000004")
    key = provider.name  # a provider_codes key nobody else uses
    await sql(
        "update public.courts set provider_codes = provider_codes || jsonb_build_object(cast(:k as text), 'GWL1') "
        "where id = :id",
        k=key, id=gwalior,
    )  # fmt: skip
    try:
        async with db.engine().connect() as c:
            assert await court_ids(c, key, ["GWL1", "TESTMPHCIND", "NOPE", None]) == {
                "GWL1": gwalior,
                "TESTMPHCIND": UUID(COURT_MPHC_IND),
            }
            assert await court_codes(c, key, [gwalior, COURT_DC_IND]) == {
                gwalior: "GWL1",
                UUID(COURT_DC_IND): "TESTDCIND",
            }
            monkeypatch.setattr(get_settings(), "courtdata_live", True)  # synthetic codes only stand in locally
            assert await court_ids(c, key, ["GWL1", "TESTMPHCIND"]) == {"GWL1": gwalior}
            assert await court_codes(c, key, [COURT_DC_IND]) == {}
    finally:
        await sql(
            "update public.courts set provider_codes = provider_codes - cast(:k as text) where id = :id",
            k=key,
            id=gwalior,
        )


async def test_court_days_skip_sundays_and_verified_holidays_only(make: Factory):
    # Sat 4 Jan 2031 onwards: Sunday 5th; MPHC Indore closed (VERIFIED) on Mon 6th, a DRAFT closure on Tue 7th.
    await sql(
        "insert into public.court_holidays (court_id, date, kind, status) values "
        "(:c, '2031-01-06', 'holiday', 'VERIFIED'), (:c, '2031-01-07', 'holiday', 'DRAFT')",
        c=COURT_MPHC_IND,
    )
    try:
        async with db.engine().connect() as c:
            start = date(2031, 1, 4)
            assert await court_days(c, [COURT_MPHC_IND], start, 3) == [
                date(2031, 1, 4),
                date(2031, 1, 7),
                date(2031, 1, 8),
            ]
            both = [date(2031, 1, 4), date(2031, 1, 6), date(2031, 1, 7)]
            assert await court_days(c, [COURT_MPHC_IND, COURT_DC_IND], start, 3) == both  # open somewhere
            assert await court_days(c, [], start, 3) == both
    finally:
        await sql(
            "delete from public.court_holidays where court_id = :c and date in ('2031-01-06', '2031-01-07')",
            c=COURT_MPHC_IND,
        )
