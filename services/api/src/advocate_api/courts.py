"""Court-data calls made by the API (spec §11): budgets checked first (§11.8), every attempt costed into
`provider_calls` and the organisation's `usage_ledger`, provider errors turned into API error codes."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from decimal import Decimal
from uuid import UUID

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text

from advocate_api.db import service_db
from advocate_api.errors import ApiError, body
from advocate_shared.ist import today_ist
from advocate_shared.settings import get_settings
from court_data.ecourtsindia import EcourtsIndiaProvider
from court_data.fake import synthetic_transport
from court_data.models import CaseNotFound, ProviderError
from court_data.router import CallRecord, ProviderRouter

# Spend in the current IST day / month, from the cost records.
DAY_SPEND = """
select coalesce(sum(cost_inr), 0) from public.provider_calls
where created_at >= (date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata')
"""
MONTH_SPEND = """
select coalesce(sum(cost_inr), 0) from public.provider_calls
where org_id = :o and created_at >= (date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata')
"""


@asynccontextmanager
async def court_data(org_id: UUID | None) -> AsyncIterator[ProviderRouter]:
    """A router over the configured providers for one request. With COURTDATA_LIVE off (local, CI) it talks to the
    synthetic stand-in, never a real provider."""
    s = get_settings()
    await check_budget(org_id)
    if s.courtdata_live and not s.ecourtsindia_api_key:
        raise ApiError(503, "COURT_PROVIDER_UNAVAILABLE", "Court data is not configured", retryable=True)
    provider = EcourtsIndiaProvider(
        base_url=s.ecourtsindia_api_base,
        api_key=s.ecourtsindia_api_key or "synthetic",
        rate_multiplier=s.courtdata_rate_multiplier,
        transport=None if s.courtdata_live else synthetic_transport(today_ist()),
    )
    calls: list[CallRecord] = []
    # ponytail: breaker state lives per request here; the workers keep long-lived routers where it matters.
    try:
        yield ProviderRouter([provider], on_call=calls.append)
    finally:
        await provider.aclose()
        await record_calls(calls, org_id)


async def check_budget(org_id: UUID | None) -> None:
    s = get_settings()
    async with service_db() as c:
        cap = s.courtdata_global_daily_cap_inr
        if cap is not None and Decimal((await c.execute(text(DAY_SPEND))).scalar_one()) >= cap:
            raise ApiError(503, "COURT_DATA_PAUSED", "Court data is paused for today", retryable=True)
        budget = s.courtdata_org_monthly_default_inr
        if org_id and budget is not None:
            spent = Decimal((await c.execute(text(MONTH_SPEND), {"o": org_id})).scalar_one())
            if spent >= budget:
                raise ApiError(429, "COURT_DATA_BUDGET_REACHED", "This month's court-data budget is used up")


async def record_calls(calls: list[CallRecord], org_id: UUID | None) -> None:
    if not calls:
        return
    async with service_db() as c:
        for call in calls:
            call_id = (
                await c.execute(
                    text(
                        "insert into public.provider_calls "
                        "(provider, operation, cnr, org_id, cost_inr, status, http_status, latency_ms) "
                        "values (:p, :op, :cnr, :o, :cost, :st, :http, :ms) returning id"
                    ),
                    {
                        "p": call.provider,
                        "op": call.operation.value,
                        "cnr": call.cnr,
                        "o": org_id,
                        "cost": call.cost_inr,
                        "st": call.status,
                        "http": call.http_status,
                        "ms": call.latency_ms,
                    },
                )
            ).scalar_one()
            if call.cost_inr:
                await c.execute(
                    text(
                        "insert into public.usage_ledger (org_id, kind, quantity, cost_inr, ref_type, ref_id) "
                        "values (:o, 'provider_call', 1, :cost, 'provider_calls', :id)"
                    ),
                    {"o": org_id, "cost": call.cost_inr, "id": call_id},
                )


def install(app: FastAPI) -> None:
    @app.exception_handler(ProviderError)
    async def _provider(_: Request, e: ProviderError) -> JSONResponse:
        if isinstance(e, CaseNotFound):
            return JSONResponse(body("CASE_NOT_FOUND", "No case with this CNR"), status_code=404)
        if e.retryable:
            return JSONResponse(
                body("COURT_PROVIDER_UNAVAILABLE", "Court records are unavailable right now", retryable=True),
                status_code=503,
            )
        return JSONResponse(body("COURT_PROVIDER_ERROR", "Court records returned an error"), status_code=502)
