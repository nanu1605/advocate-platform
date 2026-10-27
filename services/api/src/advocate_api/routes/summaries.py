"""Order summaries and order intelligence on demand (spec §10.2, §4.4 F07, F13, §14.2, ADR 0023). What is stored
already is answered at once and free. Otherwise a job makes it (advocate_workers.summaries), paid in credits the user
agreed to: a request without them gets 409 AI_CREDITS_NEEDED with the price, which the app asks about first."""

from typing import Any, Literal
from uuid import UUID

from fastapi import APIRouter, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import RowMapping, text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_api.auth import Claims, CurrentClaims
from advocate_api.db import CurrentOrg, OrgContext, UserDb, service_db
from advocate_api.errors import ApiError
from advocate_api.idempotency import Idem, IdempotencyKey
from advocate_api.jobs import create_job
from advocate_api.ratelimit import limit
from advocate_api.routes import files
from advocate_shared import ai, order_ai
from advocate_shared.tasks import ORDER_INTEL, SUMMARISE_DOCUMENT, SUMMARISE_ORDER

router = APIRouter(prefix="/v1")

ORDER = (
    "select matter_id, court_order_id, summary_hi, summary_en from public.orders "
    "where id = :id and org_id = :o and deleted_at is null"
)
# Proposals are in the owner's language, one per organisation (ADR 0023).
OWNER_LANGUAGE = (
    "select p.preferred_language from public.organizations g join public.profiles p on p.id = g.owner_id "
    "where g.id = :o"
)
# The price goes by length (§14.2). A DOCX has no page count: its chunks, about a page each, stand in.
PAGES = {
    "court_order": "select pages from public.court_orders where id = cast(:id as uuid)",
    "document": "select coalesce(pages, (select count(*) from public.document_chunks c where c.document_id = d.id)) "
    "from public.documents d where d.id = cast(:id as uuid)",
}


class SummaryIn(BaseModel):
    language: Literal["hi", "en"]
    credits: int = Field(0, ge=0)  # what the user agreed to spend; a job is charged the price


class IntelIn(BaseModel):
    order_id: UUID
    credits: int = Field(0, ge=0)


class Ready(BaseModel):
    status: Literal["ready"] = "ready"
    summary: dict[str, Any]  # OrderSummary fields and source_pages ({"S1": 1, …})


class Proposed(BaseModel):
    status: Literal["ready"] = "ready"
    proposed: int  # tasks and deadlines proposed to the organisation now ("N actions found")


class Queued(BaseModel):
    status: Literal["queued"] = "queued"
    job_id: UUID  # its row syncs to the user's devices; a summary of a court order arrives on the orders row


@router.post("/orders/{order_id}/summary")
async def summarise_order(
    idem: IdempotencyKey,
    db: UserDb,
    org: CurrentOrg,
    claims: CurrentClaims,
    request: Request,
    response: Response,
    order_id: UUID,
    body: SummaryIn,
) -> Ready | Queued:
    """A court order's summary in `language`. A stored one is also copied to the organisation's orders row."""
    await _limit(claims)
    co, order = await _order(db, org, order_id)
    summary = order[f"summary_{body.language}"]
    if summary is None:
        async with service_db() as c:
            if (summary := await order_ai.cached(c, "court_order", co, body.language)) is not None:
                await order_ai.fan_out(c, co, body.language, summary)
    if summary is not None:
        return idem.keep(Ready(summary=summary))
    pages = await _readable(org.org_id, "court_order", co)
    price = await _price(org.org_id, ai.configured_llm().config.credits_for("order_summary", pages), body.credits)
    job_input = {"order_id": order_id, "language": body.language, "credits": price}
    job_id = await create_job(
        db, request, task=SUMMARISE_ORDER, kind="order_summary", org_id=org.org_id, job_input=job_input
    )
    return _queued(idem, response, job_id)


@router.post("/documents/{document_id}/summary")
async def summarise_document(
    idem: IdempotencyKey,
    db: UserDb,
    org: CurrentOrg,
    claims: CurrentClaims,
    request: Request,
    response: Response,
    document_id: UUID,
    body: SummaryIn,
) -> Ready | Queued:
    """An uploaded order's summary in `language`, the organisation's own (`ai_answers`)."""
    await _limit(claims)
    if (await files.ready_document(db, org.org_id, document_id))["kind"] != "order":
        raise ApiError(409, "DOCUMENT_NOT_AN_ORDER", "Only an order can be summarised")
    source_id = str(document_id)
    if (summary := await order_ai.cached(db, "document", source_id, body.language)) is not None:
        return idem.keep(Ready(summary=summary))
    pages = await _readable(org.org_id, "document", source_id)
    price = await _price(org.org_id, ai.configured_llm().config.credits_for("order_summary", pages), body.credits)
    job_input = {"document_id": document_id, "language": body.language, "credits": price}
    job_id = await create_job(
        db, request, task=SUMMARISE_DOCUMENT, kind="document_summary", org_id=org.org_id, job_input=job_input
    )
    return _queued(idem, response, job_id)


@router.post("/ai/order-intel")
async def order_intel(
    idem: IdempotencyKey,
    db: UserDb,
    org: CurrentOrg,
    claims: CurrentClaims,
    request: Request,
    response: Response,
    body: IntelIn,
) -> Proposed | Queued:
    """Find actions in a court order: its intelligence in the organisation owner's language (made once, shared)
    becomes the organisation's proposed tasks and deadlines, which a member confirms (nothing is added on its own,
    hard rule 2). An order read for actions before (any task or deadline from it) is not read again."""
    org.require("owner", "advocate", "junior")
    await _limit(claims)
    co, order = await _order(db, org, body.order_id)
    async with service_db() as c:  # proposals are written as the workers write them (created_by null)
        language = (await c.execute(text(OWNER_LANGUAGE), {"o": org.org_id})).scalar_one()
        if (intel := await order_ai.cached(c, "order_intel", co, language)) is not None:
            n = await order_ai.propose(c, str(org.org_id), str(order["matter_id"]), str(body.order_id), co, intel)
            return idem.keep(Proposed(proposed=n))
        if await order_ai.proposed_before(c, str(org.org_id), str(body.order_id)):  # nothing to pay for
            return idem.keep(Proposed(proposed=0))
    await _readable(org.org_id, "court_order", co)
    async with service_db() as c:
        if await order_ai.order_date(c, co) is None:  # due dates are counted from it
            raise ApiError(409, "ORDER_DATE_UNKNOWN", "This order's date is not known")
    price = await _price(org.org_id, ai.configured_llm().config.credits_for("order_intel"), body.credits)
    job_input = {"order_id": body.order_id, "language": language, "credits": price}
    job_id = await create_job(db, request, task=ORDER_INTEL, kind="order_intel", org_id=org.org_id, job_input=job_input)
    return _queued(idem, response, job_id)


async def _limit(claims: Claims) -> None:
    await limit(f"ai:{claims['sub']}", 30, 60)  # ponytail: one limit for every plan until plans are billed (§10.1)


async def _order(db: AsyncConnection, org: OrgContext, order_id: UUID) -> tuple[str, RowMapping]:
    """The organisation's live order and its court order's id. An order typed in by hand has no court copy to read."""
    order = (await db.execute(text(ORDER), {"id": order_id, "o": org.org_id})).mappings().one_or_none()
    if order is None:
        raise ApiError(404, "NOT_FOUND", "Order not found")
    if order["court_order_id"] is None:
        raise ApiError(409, "ORDER_SUMMARY_UNAVAILABLE", "This order has no court copy to read")
    return str(order["court_order_id"]), order


async def _readable(org_id: UUID, kind: order_ai.Kind, source_id: str) -> int:
    """The source's length in pages once its text is read. Until then 409 ORDER_TEXT_PENDING, and a court order's PDF
    is fetched as when it is opened (the text is read next), so the app retries."""
    async with service_db() as c:
        state = await order_ai.text_state(c, kind, source_id)
        pages = (await c.execute(text(PAGES[kind]), {"id": source_id})).scalar_one_or_none()
    if state == "pending":
        if kind == "court_order":
            try:
                await files.order_pdf(org_id, UUID(source_id))
            except ApiError as e:
                if e.code != "ORDER_PDF_FETCHING":  # else another request is fetching it
                    raise
        raise ApiError(409, "ORDER_TEXT_PENDING", "This order is still being read", retryable=True)
    if state == "unreadable":
        raise ApiError(409, "ORDER_TEXT_UNREADABLE", "This order's text can't be read")
    if state is None:
        raise ApiError(404, "NOT_FOUND", "Order not found")
    return pages or 1


async def _price(org_id: UUID, price: int, offered: int) -> int:
    """`price`, once the organisation has the credits left this month and the user has agreed to spend them.
    ponytail: checked, not held (the job checks again before the model is called): runs in flight together can spend
    past the month's credits by a price each; reserve credits if that shows up."""
    async with service_db() as c:  # the ledger is the owner's to read (RLS)
        left = await ai.credits_left(c, org_id)
    details = {"credits": price, "left": left}
    if left < price:  # before asking: agreeing would not help
        raise ApiError(402, "AI_CREDITS_EXHAUSTED", "Not enough AI credits left this month", details=details)
    if offered < price:
        raise ApiError(409, "AI_CREDITS_NEEDED", "This uses AI credits", details=details)
    return price


def _queued(idem: Idem, response: Response, job_id: UUID) -> Queued:
    response.status_code = idem.status = 202  # a replay answers 202 too
    return idem.keep(Queued(job_id=job_id))
