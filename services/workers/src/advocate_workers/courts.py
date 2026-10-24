"""Court data for workers (spec §11): provider access with budgets (§11.8) and cost records, court-code mapping and
court days. Every provider call goes through CourtData.call: budgets are checked before each paid call, and the
attempt is recorded right after it, so the next check already counts it."""

from collections.abc import Awaitable, Callable, Iterable, Sequence
from datetime import date
from decimal import Decimal
from enum import StrEnum
from typing import Self
from uuid import UUID

import structlog
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_shared.courtdata import IST_MONTH_START, configured_provider, day_spend, month_spend, record_calls
from advocate_shared.settings import get_settings
from advocate_workers import db
from advocate_workers.jobs import JobFailed
from court_data.models import Capability, CourtDataProvider
from court_data.router import CallRecord, ProviderRouter

log = structlog.get_logger()

# COURTDATA_LIVE=0 only: the synthetic stand-in's court codes → the seeded courts (ids fixed in the court_diary
# migration). Real codes live in courts.provider_codes; these never go into the database.
SYNTHETIC_COURTS = {
    "TESTSC": UUID("c0000000-0000-0000-0000-000000000001"),
    "TESTMPHCJBP": UUID("c0000000-0000-0000-0000-000000000002"),
    "TESTMPHCIND": UUID("c0000000-0000-0000-0000-000000000003"),
    "TESTDCIND": UUID("c0000000-0000-0000-0000-000000000005"),
}


class Spend(StrEnum):
    """Who pays for a call and which budget can pause it (§11.8)."""

    PROTECTED = "protected"  # cause_list_tomorrow, first post_hearing_refresh: platform row, never paused
    PLATFORM = "platform"  # post_hearing_retry_1, weekly_sweep: platform row, paused at the global daily cap
    SHARED = "shared"  # post_hearing_retry_2, order_pipeline: like PLATFORM, and callers drop_over_budget() first
    ORG = "org"  # find_cases, auto_match, advocate_watch, fetch_cases, refresh_case: org row, global cap or org budget


class Paused(JobFailed):
    """A budget stops the call: COURT_DATA_PAUSED (global daily cap) or COURT_DATA_BUDGET_REACHED (the organisation's
    monthly budget). A user job fails with it; scheduled jobs stop or skip."""


def make_providers(today: date) -> list[CourtDataProvider]:
    """Providers in priority order. The one place tests swap in a fake provider."""
    return [configured_provider(today)]


OPEN_CNRS = f"""
select distinct m.cnr from public.matters m
where m.cnr = any(:cnrs) and m.deleted_at is null and m.tracking = 'auto'
  and (select coalesce(sum(p.cost_inr), 0) from public.provider_calls p
       where p.org_id = m.org_id and p.created_at >= {IST_MONTH_START}) < :budget
"""  # noqa: S608 (a constant)


class CourtData:
    """Provider access for one run: `async with CourtData(r, today) as cd: await cd.call(...)`. The circuit breaker
    lives as long as the run."""

    def __init__(self, r: Redis, today: date):
        self._r, self._today = r, today
        self._calls: list[CallRecord] = []
        self.providers = make_providers(today)
        self.router = ProviderRouter(self.providers, on_call=self._calls.append)

    @property
    def provider(self) -> str:
        """The primary provider, whose court codes searches use."""
        return self.providers[0].name

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *_: object) -> None:
        for p in self.providers:
            if close := getattr(p, "aclose", None):
                await close()

    async def call[T](
        self,
        spend: Spend,
        op: Capability,
        fn: Callable[[CourtDataProvider], Awaitable[T]],
        *,
        org_id: str | None = None,
        cnr: str | None = None,
        n: int = 1,
    ) -> T:
        """Check the budgets for `spend`, then run `fn` through the router. Raises Paused, or the provider's error.
        `n` is the billed unit count (CNRs in a batch). ORG calls are costed to `org_id`, the rest are platform rows."""
        if spend is Spend.ORG and not org_id:
            raise ValueError("an org-costed call needs org_id")
        await self.check(spend, org_id)
        try:
            return await self.router.run(op, fn, n=n, cnr=cnr, org_id=org_id)
        finally:
            calls = self._calls[:]
            self._calls.clear()
            if calls:
                async with db.engine().begin() as c:
                    await record_calls(c, calls, org_id if spend is Spend.ORG else None)

    async def check(self, spend: Spend, org_id: str | None = None) -> None:
        s = get_settings()
        cap, budget = s.courtdata_global_daily_cap_inr, s.courtdata_org_monthly_default_inr
        async with db.engine().connect() as c:
            if cap is not None:
                spent = await day_spend(c)
                await self._alert("global", spent, cap)
                if spent >= cap and spend is not Spend.PROTECTED:
                    raise Paused("COURT_DATA_PAUSED")
            if spend is Spend.ORG and org_id and budget is not None:
                spent = await month_spend(c, org_id)
                await self._alert(f"org:{org_id}", spent, budget)
                if spent >= budget:
                    raise Paused("COURT_DATA_BUDGET_REACHED")

    async def drop_over_budget(self, cnrs: list[str]) -> list[str]:
        """For SHARED fetches: the CNRs still worth fetching, i.e. tracked by at least one organisation under its
        monthly budget (all of them while there is no budget)."""
        budget = get_settings().courtdata_org_monthly_default_inr
        if budget is None or not cnrs:
            return cnrs
        async with db.engine().connect() as c:
            keep = {r["cnr"] for r in await db.rows(c, OPEN_CNRS, cnrs=cnrs, budget=budget)}
        return [cnr for cnr in cnrs if cnr in keep]

    async def _alert(self, scope: str, spent: Decimal, limit: Decimal) -> None:
        """80% and 100% are logged once per day per scope: the admin / founder alert until the P3 admin view."""
        level = 100 if spent >= limit else 80 if spent >= limit * Decimal("0.8") else None
        if level and await self._r.set(f"budget-alert:{scope}:{level}:{self._today}", "1", nx=True, ex=2 * 86400):
            emit = log.error if level == 100 else log.warning
            emit("court_data_budget", scope=scope, percent=level, spent_inr=str(spent), limit_inr=str(limit))


async def court_ids(conn: AsyncConnection, provider: str, codes: Iterable[str | None]) -> dict[str, UUID]:
    """Provider court codes → courts.id (courts.provider_codes, plus the synthetic codes when not live)."""
    wanted = sorted({c for c in codes if c})
    if not wanted:
        return {}
    found = await db.rows(
        conn,
        "select provider_codes->>:p as code, id from public.courts where provider_codes->>:p = any(:codes)",
        p=provider,
        codes=wanted,
    )
    mapped = {r["code"]: r["id"] for r in found}
    if not get_settings().courtdata_live:
        mapped = {c: SYNTHETIC_COURTS[c] for c in wanted if c in SYNTHETIC_COURTS} | mapped
    return mapped


async def court_codes(conn: AsyncConnection, provider: str, ids: Iterable[UUID | str]) -> dict[UUID, str]:
    """courts.id → the provider's court code, for courts that have one."""
    wanted = sorted({UUID(str(i)) for i in ids})
    found = await db.rows(
        conn,
        "select id, provider_codes->>:p as code from public.courts "
        "where id = any(:ids) and provider_codes->>:p is not null",
        p=provider,
        ids=wanted,
    )
    mapped = {r["id"]: r["code"] for r in found}
    if not get_settings().courtdata_live:
        mapped = {i: c for c, i in SYNTHETIC_COURTS.items() if i in wanted} | mapped
    return mapped


COURT_DAYS = """
select cast(:start as date) + i as day from generate_series(0, 90) i
where case when cardinality(cast(:courts as uuid[])) = 0 then extract(isodow from cast(:start as date) + i) <> 7
  else exists (select 1 from unnest(cast(:courts as uuid[])) c where public.is_court_day(c, cast(:start as date) + i))
end
order by i limit :n
"""


async def court_days(conn: AsyncConnection, court_ids: Sequence[UUID | str], start: date, n: int) -> list[date]:
    """The first `n` days from `start` (inclusive) that are court days for at least one of `court_ids`, or any day
    but Sunday when no court is given. A court day: not Sunday and not a VERIFIED holiday (public.is_court_day)."""
    found = await db.rows(conn, COURT_DAYS, start=start, courts=[UUID(str(c)) for c in court_ids], n=n)
    return [r["day"] for r in found]
