"""AI run records, the shared summary cache, the automatic cap, credits and the cost alerts (spec §12.14)."""

import uuid
from datetime import date
from decimal import Decimal

import pytest
from conftest import Factory, sql
from structlog.testing import capture_logs

from advocate_shared import ai
from advocate_shared.settings import get_settings
from advocate_workers import db
from advocate_workers.ai import run_cost_watch
from legal_ai.contracts import OrderSummary
from legal_ai.llm import Run
from legal_ai.prompts import Source


def run(status: str = "ok", cost: str = "1.5000", task: str = "ask_case") -> Run:
    return Run(task, "v1", "standard", "in.local.standard", 1200, 300, Decimal(cost), 900, status)  # type: ignore[arg-type]


async def ledger(org_id: str) -> list[tuple[str, Decimal, Decimal]]:
    rows = await sql(
        "select kind, quantity, cost_inr from public.usage_ledger where org_id = :o order by kind", o=org_id
    )
    return [(r["kind"], r["quantity"], r["cost_inr"]) for r in rows]


async def backdated_run(org_id: str, cost: str, days_ago: int) -> None:
    await sql(
        "insert into public.ai_runs (org_id, kind, model_tier, model_id, cost_inr, status, created_at) "
        "values (:o, 'order_summary', 'standard', 'in.local.standard', :c, 'ok', now() - make_interval(days => :d))",
        o=org_id, c=Decimal(cost), d=days_ago,
    )  # fmt: skip


async def test_a_local_run_is_recorded_without_text(make: Factory):
    org = await make.org()
    r = await ai.configured_llm().structured(
        "order_summary", OrderSummary, language="hi", sources=[Source("order", "Order dated 01.10.2026", page=1)]
    )
    async with db.engine().begin() as c:
        run_id = await ai.record_run(c, r.run, org_id=org.id, user_id=org.owner_id, billing="automatic")
    [row] = await sql("select * from public.ai_runs where id = :id", id=run_id)
    assert (row["kind"], row["prompt_version"], row["model_tier"], row["status"]) == ("order_summary", "v1",
                                                                                      "standard", "ok")  # fmt: skip
    assert row["output_tokens"] > 0 and row["cost_inr"] == r.run.cost_inr > 0
    assert not {"prompt", "answer", "text", "output"} & set(row)  # §9.2: no prompt or answer text
    assert await ledger(org.id) == [("ai_automatic", 1, r.run.cost_inr)]


async def test_credits_are_charged_only_for_output(make: Factory):
    org = await make.org()
    async with db.engine().begin() as c:
        await ai.record_run(c, run(), org_id=org.id, billing="credits", credits=20)
        await ai.record_run(c, run("invalid_output"), org_id=org.id, billing="credits", credits=20)
        await ai.record_run(c, run("unavailable", "0"), org_id=org.id, billing="automatic")
        await ai.record_run(c, run(), org_id=org.id)  # unbilled, e.g. a cached summary's first user
    assert await ledger(org.id) == [("ai_automatic", 1, 0), ("ai_credit", 20, Decimal("1.5"))]
    [n] = await sql("select count(*) as n from public.ai_runs where org_id = :o", o=org.id)
    assert n["n"] == 4


async def test_billing_needs_an_organisation_and_a_price(make: Factory):
    org = await make.org()
    async with db.engine().begin() as c:
        with pytest.raises(ValueError, match="organisation"):
            await ai.record_run(c, run(), billing="automatic")
        with pytest.raises(ValueError, match="credit"):
            await ai.record_run(c, run(), org_id=org.id, billing="credits")


async def test_plan_limits_pool_a_chambers_members(make: Factory):
    solo = await make.org()
    small = await make.org("A", members={"B": "advocate"})  # 2 active: billed as the 3-seat minimum
    big = await make.org("C", members={"D": "advocate", "E": "junior", "F": "clerk", "G": "advocate"})
    await sql("update public.memberships set status = 'removed' where user_id = :u", u=big.users["G"])
    async with db.engine().connect() as c:
        got = [await ai.limits(c, o.id) for o in (solo, small, big)]
    assert got == [ai.Limits(420, Decimal(40)), ai.Limits(1080, Decimal(105)), ai.Limits(1440, Decimal(140))]


async def test_credits_left_counts_this_month_only(make: Factory):
    org = await make.org()
    async with db.engine().begin() as c:
        await ai.record_run(c, run(), org_id=org.id, billing="credits", credits=20)
        await ai.record_run(c, run(), org_id=org.id, billing="credits", credits=4)
    await sql(
        "insert into public.usage_ledger (org_id, kind, quantity, created_at) "
        "values (:o, 'ai_credit', 300, now() - interval '40 days')",
        o=org.id,
    )
    async with db.engine().connect() as c:
        assert await ai.credits_left(c, org.id) == 420 - 24


async def test_automatic_ai_runs_until_the_cap_then_on_open(make: Factory, monkeypatch):
    monkeypatch.setattr(get_settings(), "ai_platform_daily_budget_inr", None)
    org = await make.org()
    async with db.engine().begin() as c:
        await ai.record_run(c, run(cost="39.9999", task="order_summary"), org_id=org.id, billing="automatic")
        assert await ai.automatic(c, org.id) is ai.Automatic.RUN
        await ai.record_run(c, run(cost="0.0001", task="order_intel"), org_id=org.id, billing="automatic")
        assert await ai.automatic(c, org.id) is ai.Automatic.ON_OPEN  # ₹40: Solo's cap


async def test_automatic_ai_waits_once_the_platform_budget_is_spent(make: Factory, monkeypatch):
    org = await make.org()
    async with db.engine().begin() as c:
        await ai.record_run(c, run(cost="0.5000"), org_id=org.id)
        monkeypatch.setattr(get_settings(), "ai_platform_daily_budget_inr", Decimal("0.5"))
        assert await ai.automatic(c, org.id) is ai.Automatic.LATER


async def test_summary_cache_is_per_language_and_prompt_version():
    ref = str(uuid.uuid4())
    try:
        async with db.engine().begin() as c:
            await ai.store_summary(c, "court_order", ref, "hi", {"gist": "पहला"}, run())
            await ai.store_summary(c, "court_order", ref, "hi", {"gist": "दूसरा"}, run())
            assert await ai.cached_summary(c, "court_order", ref, "hi", "v1") == {"gist": "दूसरा"}
            assert await ai.cached_summary(c, "court_order", ref, "en", "v1") is None
            assert await ai.cached_summary(c, "court_order", ref, "hi", "v2") is None
    finally:
        await sql("delete from public.public_summaries where doc_ref = :r", r=ref)


async def test_cost_watch_alerts_on_a_spike_once_a_day(make: Factory, r, monkeypatch):
    monkeypatch.setattr(get_settings(), "ai_platform_daily_budget_inr", None)
    spiky, steady, new, young = await make.org("A"), await make.org("B"), await make.org("C"), await make.org("D")
    for days_ago in range(1, 31):
        await backdated_run(spiky.id, "1", days_ago)  # ₹1 a day
        await backdated_run(steady.id, "10", days_ago)  # ₹10 a day
    for days_ago in range(1, 6):
        await backdated_run(young.id, "12", days_ago)  # 5 days of ₹12: averages ₹12, not 60 / 30
    await backdated_run(spiky.id, "20", 0)  # 20 > 3 x 1
    await backdated_run(steady.id, "20", 0)  # 20 < 3 x 10
    await backdated_run(new.id, "5", 0)  # no history, under the floor
    await backdated_run(young.id, "12", 0)
    day = date(2000, 1, 1).replace(day=1 + uuid.uuid4().int % 28)  # alert keys of this test only
    try:
        with capture_logs() as logs:
            first = await run_cost_watch(r, day)
            second = await run_cost_watch(r, day)
        assert spiky.id in first and spiky.id in second and not {steady.id, new.id, young.id} & set(first)
        alerts = [e for e in logs if e["event"] == "ai_cost_spike" and e["org_id"] == spiky.id]
        assert len(alerts) == 1 and alerts[0]["today_inr"] == "20.0000"
    finally:
        await r.delete(*[f"ai-cost-spike:{o.id}:{day}" for o in (spiky, steady, new, young)])


async def test_cost_watch_warns_at_80_and_100_percent_of_the_platform_budget(make: Factory, r, monkeypatch):
    org = await make.org()
    await backdated_run(org.id, "1", 0)
    async with db.engine().connect() as c:
        spent = await ai.day_spend(c)
    day = date(2001, 1, 1).replace(day=1 + uuid.uuid4().int % 28)
    try:
        with capture_logs() as logs:
            monkeypatch.setattr(get_settings(), "ai_platform_daily_budget_inr", spent / Decimal("0.9"))
            await run_cost_watch(r, day)
            monkeypatch.setattr(get_settings(), "ai_platform_daily_budget_inr", spent)
            await run_cost_watch(r, day)
            await run_cost_watch(r, day)
        assert [(e["log_level"], e["percent"]) for e in logs if e["event"] == "ai_platform_budget"] == [
            ("warning", 80),
            ("error", 100),
        ]
    finally:
        await r.delete(f"ai-budget-alert:80:{day}", f"ai-budget-alert:100:{day}")
