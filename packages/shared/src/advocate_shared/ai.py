"""AI plumbing shared by the API and the workers (spec §12.14, ADR 0020): the configured client, the record each run
leaves in `ai_runs` and `usage_ledger`, the shared summary cache, and the automatic-AI cap and credits that hold an
organisation's AI spend. Writes need the service connection: these tables have no user write path."""

import json
from dataclasses import dataclass
from decimal import Decimal
from enum import StrEnum
from functools import cache
from typing import Any, Literal
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_shared.courtdata import IST_DAY_START, IST_MONTH_START
from advocate_shared.settings import get_settings
from legal_ai.config import load_config
from legal_ai.fake import local_transport
from legal_ai.llm import BedrockTransport, LLMClient, Run

# S608: built from the constants above only.
DAY_SPEND = f"select coalesce(sum(cost_inr), 0) from public.ai_runs where created_at >= {IST_DAY_START}"  # noqa: S608
MONTH_LEDGER = (
    "select coalesce(sum(quantity), 0) as quantity, coalesce(sum(cost_inr), 0) as cost "  # noqa: S608
    f"from public.usage_ledger where org_id = :o and kind = :k and created_at >= {IST_MONTH_START}"
)
# ponytail: the plan follows the organisation's kind until subscriptions (P3) record what each one pays for.
LIMITS = """
select o.kind, p.limits,
       (select count(*) from public.memberships m where m.org_id = o.id and m.status = 'active') as members
from public.organizations o
join public.plans p on p.id = case o.kind when 'chamber' then 'chamber' else 'solo' end
where o.id = :o
"""


@cache
def configured_llm() -> LLMClient:
    """Bedrock in ap-south-1 when AI_LIVE is on. Otherwise the local stand-in (legal_ai.fake): local runs and CI
    never call a model."""
    s = get_settings()
    env = {k.upper(): str(v) for k, v in s.model_dump().items() if v is not None}
    if not s.ai_live:
        env |= {f"BEDROCK_PROFILE_{tier.upper()}": f"in.local.{tier}" for tier in ("fast", "standard", "deep")}
        return LLMClient(load_config(env=env), local_transport)
    cfg = load_config(env=env)
    return LLMClient(cfg, BedrockTransport(cfg.providers.bedrock_india))


async def record_run(
    conn: AsyncConnection,
    run: Run,
    *,
    org_id: UUID | str | None = None,
    user_id: UUID | str | None = None,
    matter_id: UUID | str | None = None,
    billing: Literal["automatic", "credits"] | None = None,
    credits: int = 0,
) -> UUID:
    """The run's `ai_runs` row and, when an organisation pays, its ledger row: automatic AI counts against the cap
    whatever the outcome (it cost what it cost); credits are charged only for a run that produced output."""
    if billing and not org_id:
        raise ValueError("billing needs the organisation that pays")
    if billing == "credits" and credits <= 0:
        raise ValueError("an on-demand run is charged at least one credit")
    run_id = (
        await conn.execute(
            text(
                "insert into public.ai_runs (org_id, user_id, matter_id, kind, prompt_version, model_tier, model_id, "
                "input_tokens, output_tokens, cost_inr, latency_ms, status, error_code) "
                "values (:o, :u, :m, :k, :v, :tier, :model, :tin, :tout, :cost, :ms, :st, :err) returning id"
            ),
            {
                "o": org_id,
                "u": user_id,
                "m": matter_id,
                "k": run.task,
                "v": run.prompt_version,
                "tier": run.model_tier,
                "model": run.model_id,
                "tin": run.input_tokens,
                "tout": run.output_tokens,
                "cost": run.cost_inr,
                "ms": run.latency_ms,
                "st": run.status,
                "err": run.error_code,
            },
        )
    ).scalar_one()
    kind, quantity = {"automatic": ("ai_automatic", 1), "credits": ("ai_credit", credits)}.get(billing or "", (None, 0))
    if kind and (billing == "automatic" or run.status == "ok"):
        await conn.execute(
            text(
                "insert into public.usage_ledger (org_id, kind, quantity, cost_inr, ref_type, ref_id) "
                "values (:o, :k, :q, :cost, 'ai_runs', :id)"
            ),
            {"o": org_id, "k": kind, "q": quantity, "cost": run.cost_inr, "id": run_id},
        )
    return run_id


# ---------------------------------------------------------------- shared summaries (§12.1 rule 7)


async def cached_summary(
    conn: AsyncConnection, doc_kind: str, doc_ref: str, language: str, prompt_version: str
) -> dict[str, Any] | None:
    """The cached summary of a public document, if it was made with this prompt version (a new version regenerates
    it)."""
    row = await conn.execute(
        text(
            "select summary from public.public_summaries "
            "where doc_kind = :k and doc_ref = :r and language = :l and prompt_version = :v"
        ),
        {"k": doc_kind, "r": doc_ref, "l": language, "v": prompt_version},
    )
    summary = row.scalar_one_or_none()
    return json.loads(summary) if isinstance(summary, str) else summary


async def store_summary(
    conn: AsyncConnection, doc_kind: str, doc_ref: str, language: str, summary: dict[str, Any], run: Run
) -> None:
    await conn.execute(
        text(
            "insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) "
            "values (:k, :r, :l, cast(:s as jsonb), :model, :v) "
            "on conflict (doc_kind, doc_ref, language) do update set "
            "summary = excluded.summary, model_id = excluded.model_id, prompt_version = excluded.prompt_version"
        ),
        {
            "k": doc_kind,
            "r": doc_ref,
            "l": language,
            "s": json.dumps(summary, ensure_ascii=False),
            "model": run.model_id,
            "v": run.prompt_version,
        },
    )


# ---------------------------------------------------------------- the automatic cap and credits (§12.14, §14.2)


@dataclass(frozen=True)
class Limits:
    credits: int  # a month
    automatic_cap_inr: Decimal  # a month


class Automatic(StrEnum):
    RUN = "run"  # within the organisation's automatic-AI cap: generate now
    ON_OPEN = "on_open"  # cap reached this month: generate when a user opens it, paid in credits
    LATER = "later"  # the platform's daily AI budget is spent: queue it (non-urgent)


async def limits(conn: AsyncConnection, org_id: UUID | str) -> Limits:
    """The plan's monthly AI allowances; a chamber's are per member, pooled (at least its minimum seats)."""
    row = (await conn.execute(text(LIMITS), {"o": org_id})).mappings().one()
    plan = row["limits"] if isinstance(row["limits"], dict) else json.loads(row["limits"])
    seats = max(row["members"], plan["min_seats"]) if row["kind"] == "chamber" else 1
    return Limits(plan["ai_credits"] * seats, Decimal(str(plan["automatic_ai_cap_inr"])) * seats)


async def _month(conn: AsyncConnection, org_id: UUID | str, kind: str) -> tuple[Decimal, Decimal]:
    row = (await conn.execute(text(MONTH_LEDGER), {"o": org_id, "k": kind})).mappings().one()
    return Decimal(row["quantity"]), Decimal(row["cost"])


async def day_spend(conn: AsyncConnection) -> Decimal:
    """Everything AI cost today (IST), organisations and platform alike."""
    return Decimal((await conn.execute(text(DAY_SPEND))).scalar_one())


async def credits_left(conn: AsyncConnection, org_id: UUID | str) -> int:
    used, _ = await _month(conn, org_id, "ai_credit")
    return (await limits(conn, org_id)).credits - int(used)


async def automatic(conn: AsyncConnection, org_id: UUID | str) -> Automatic:
    """Whether `org_id`'s next automatic summary or order intelligence runs now (§12.14)."""
    budget = get_settings().ai_platform_daily_budget_inr
    if budget is not None and await day_spend(conn) >= budget:
        return Automatic.LATER
    _, spent = await _month(conn, org_id, "ai_automatic")
    return Automatic.RUN if spent < (await limits(conn, org_id)).automatic_cap_inr else Automatic.ON_OPEN
