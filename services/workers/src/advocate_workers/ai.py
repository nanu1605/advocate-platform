"""AI cost alerts (spec §12.14), hourly: an organisation spending more today than 3x its daily average over the last
30 days (or the days it has used AI, if fewer), and the platform's AI spend against AI_PLATFORM_DAILY_BUDGET_INR
(past it, automatic AI already waits: advocate_shared.ai.automatic). Each alert is logged once a day per scope, the
admin alert until the P3 admin view."""

from datetime import date
from decimal import Decimal

import structlog
from redis.asyncio import Redis

from advocate_shared import ai
from advocate_shared.courtdata import IST_DAY_START
from advocate_shared.ist import now_ist
from advocate_shared.settings import get_settings
from advocate_workers import db, jobs
from advocate_workers.celery_app import AI_COST_WATCH, app

log = structlog.get_logger()
# ponytail: a first day has no average, so a floor keeps small first-day spend quiet; tune once beta spend is known.
SPIKE_FLOOR_INR = Decimal(10)
TODAY = f"created_at >= {IST_DAY_START}"
# The average is over the days the organisation has used AI in the window (up to 30), not always 30, so a new
# organisation's steady spend isn't a spike. S608: built from the constants above only.
DAYS = f"greatest(1, least(30, ceil(extract(epoch from {IST_DAY_START} - first) / 86400)))"
SPIKES = f"""
select org_id, today, past / {DAYS} as average
from (
  select org_id,
         coalesce(sum(cost_inr) filter (where {TODAY}), 0) as today,
         coalesce(sum(cost_inr) filter (where not ({TODAY})), 0) as past,
         min(created_at) as first
  from public.ai_runs
  where org_id is not null and created_at >= {IST_DAY_START} - interval '30 days'
  group by org_id
) d
where today > 3 * past / {DAYS} and today >= :floor
"""  # noqa: S608


async def run_cost_watch(r: Redis, today: date) -> list[str]:
    """Logs today's alerts; returns the organisations over 3x their average."""
    async with db.engine().connect() as c:
        spikes = await db.rows(c, SPIKES, floor=SPIKE_FLOOR_INR)
        spent = await ai.day_spend(c)
    for s in spikes:
        if await r.set(f"ai-cost-spike:{s['org_id']}:{today}", "1", nx=True, ex=2 * 86400):
            today_inr, average_inr = str(s["today"]), str(round(s["average"], 2))
            log.error("ai_cost_spike", org_id=str(s["org_id"]), today_inr=today_inr, average_inr=average_inr)
    budget = get_settings().ai_platform_daily_budget_inr
    level = None if budget is None else 100 if spent >= budget else 80 if spent >= budget * Decimal("0.8") else None
    if level and await r.set(f"ai-budget-alert:{level}:{today}", "1", nx=True, ex=2 * 86400):
        (log.error if level == 100 else log.warning)(
            "ai_platform_budget", percent=level, spent_inr=str(spent), limit_inr=str(budget)
        )
    return [str(s["org_id"]) for s in spikes]


@app.task(name=AI_COST_WATCH)
def ai_cost_watch() -> int:
    return len(jobs.run_task(lambda r: run_cost_watch(r, now_ist().date())))
