"""Court-data plumbing shared by the API and the workers (spec §11.2, §11.8): the configured provider, spend in the
current IST day / month, and the cost record every provider attempt leaves in `provider_calls` and `usage_ledger`."""

from datetime import date
from decimal import Decimal
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_shared.settings import get_settings
from court_data.ecourtsindia import EcourtsIndiaProvider
from court_data.fake import synthetic_transport
from court_data.models import ProviderError
from court_data.router import CallRecord

IST_DAY_START = "(date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata')"
IST_MONTH_START = "(date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata')"
# S608: built from the constants above only.
DAY_SPEND = f"select coalesce(sum(cost_inr), 0) from public.provider_calls where created_at >= {IST_DAY_START}"  # noqa: S608
MONTH_SPEND = (
    "select coalesce(sum(cost_inr), 0) from public.provider_calls "  # noqa: S608
    f"where org_id = :o and created_at >= {IST_MONTH_START}"
)


def configured_provider(today: date) -> EcourtsIndiaProvider:
    """The primary provider. With COURTDATA_LIVE off (local, CI) it talks to the synthetic stand-in, never a real
    provider; `today` shifts the synthetic dates so there is always a "tomorrow"."""
    s = get_settings()
    if s.courtdata_live and not s.ecourtsindia_api_key:
        raise ProviderError("COURT_PROVIDER_UNAVAILABLE", "court data is not configured", retryable=True)
    return EcourtsIndiaProvider(
        base_url=s.ecourtsindia_api_base,
        api_key=s.ecourtsindia_api_key or "synthetic",
        rate_multiplier=s.courtdata_rate_multiplier,
        transport=None if s.courtdata_live else synthetic_transport(today),
    )


async def day_spend(conn: AsyncConnection) -> Decimal:
    """Everything spent today (IST), organisations and platform rows alike: the global daily cap counts this."""
    return Decimal((await conn.execute(text(DAY_SPEND))).scalar_one())


async def month_spend(conn: AsyncConnection, org_id: UUID | str) -> Decimal:
    """What `org_id`'s own calls cost this month (IST); shared platform fetches are not counted."""
    return Decimal((await conn.execute(text(MONTH_SPEND), {"o": org_id})).scalar_one())


async def record_calls(conn: AsyncConnection, calls: list[CallRecord], org_id: UUID | str | None) -> None:
    """One `provider_calls` row per attempt and a `usage_ledger` row per billed one, for `org_id` or, when None,
    as a platform row for a shared fetch (§11.8)."""
    for call in calls:
        call_id = (
            await conn.execute(
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
            await conn.execute(
                text(
                    "insert into public.usage_ledger (org_id, kind, quantity, cost_inr, ref_type, ref_id) "
                    "values (:o, 'provider_call', 1, :cost, 'provider_calls', :id)"
                ),
                {"o": org_id, "cost": call.cost_inr, "id": call_id},
            )
