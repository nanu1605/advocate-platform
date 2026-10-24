"""Court-data calls made by the API (spec §11): budgets checked first (§11.8), every attempt costed into
`provider_calls` and the organisation's `usage_ledger`, provider errors turned into API error codes. The spend
queries, cost records and provider set-up are shared with the workers (advocate_shared.courtdata)."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import UUID

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from advocate_api.db import service_db
from advocate_api.errors import ApiError, body
from advocate_shared.courtdata import configured_provider, day_spend, month_spend, record_calls
from advocate_shared.ist import today_ist
from advocate_shared.settings import get_settings
from court_data.models import CaseNotFound, ProviderError
from court_data.router import CallRecord, ProviderRouter


@asynccontextmanager
async def court_data(org_id: UUID | None) -> AsyncIterator[ProviderRouter]:
    """A router over the configured providers for one request. With COURTDATA_LIVE off (local, CI) it talks to the
    synthetic stand-in, never a real provider."""
    await check_budget(org_id)
    provider = configured_provider(today_ist())  # unconfigured live provider: 503 COURT_PROVIDER_UNAVAILABLE
    calls: list[CallRecord] = []
    # ponytail: breaker state lives per request here; the workers keep long-lived routers where it matters.
    try:
        yield ProviderRouter([provider], on_call=calls.append)
    finally:
        await provider.aclose()
        if calls:
            async with service_db() as c:
                await record_calls(c, calls, org_id)


async def check_budget(org_id: UUID | None) -> None:
    s = get_settings()
    async with service_db() as c:
        cap = s.courtdata_global_daily_cap_inr
        if cap is not None and await day_spend(c) >= cap:
            raise ApiError(503, "COURT_DATA_PAUSED", "Court data is paused for today", retryable=True)
        budget = s.courtdata_org_monthly_default_inr
        if org_id and budget is not None and await month_spend(c, org_id) >= budget:
            raise ApiError(429, "COURT_DATA_BUDGET_REACHED", "This month's court-data budget is used up")


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
