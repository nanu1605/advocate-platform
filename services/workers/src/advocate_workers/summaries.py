"""Order summaries and order intelligence (spec §11.5 order_pipeline, §12.8, §4.4 F07, F13, ADR 0023); the shared
work is in advocate_shared.order_ai.

ORDER_AI runs once a court order's text is read (text.py). For the organisations that auto-track its case it makes
the summary in every language their active members prefer, then, for an order from the last RECENT_DAYS days, the
order intelligence in each organisation owner's language, and proposes its tasks and deadlines to each organisation,
rewriting the new-order message with the count. Each output is made once and billed to the automatic-AI cap of the
oldest organisation that needs it and is within its cap; the others read it free (ADR 0020). When all are over their
cap it is left to their members, on demand. A spent platform budget, or a busy model, retries the task in RETRY_S,
up to MAX_ATTEMPTS times.

The jobs (SUMMARISE_ORDER, SUMMARISE_DOCUMENT, ORDER_INTEL) are a member's on-demand request, paid in the job's
credits unless the output is stored already (the API asks before spending)."""

from collections.abc import Awaitable
from datetime import date
from typing import Any

import structlog
from celery import Task
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_shared import ai, order_ai, tasks
from advocate_shared.ai import Automatic
from advocate_shared.ist import today_ist
from advocate_workers import db, jobs, notify
from advocate_workers.celery_app import ORDER_AI, app
from advocate_workers.diff import Event
from legal_ai.llm import AIError

log = structlog.get_logger()

RECENT_DAYS = 30  # older orders (an imported case's) get summaries, never proposals
RETRY_S = 30 * 60
MAX_ATTEMPTS = 6

COURT_ORDER = "select cnr, provider_ref from public.court_orders where id = cast(:id as uuid)"
# The organisations that auto-track the order's case, oldest first, with what notify.case_label needs, their orders
# row, the languages of their active members and their owner's.
TRACKING = """
select m.id::text, m.org_id::text, m.cnr, m.case_type, m.case_number, m.case_year, m.title, o.id::text as order_id,
       op.preferred_language as owner_language,
       array(select distinct p.preferred_language from public.memberships ms
             join public.profiles p on p.id = ms.user_id
             where ms.org_id = m.org_id and ms.status = 'active') as languages
from public.matters m
join public.organizations g on g.id = m.org_id
join public.profiles op on op.id = g.owner_id
left join public.orders o on o.matter_id = m.id and o.court_order_id = cast(:co as uuid) and o.deleted_at is null
where m.cnr = :cnr and m.tracking = 'auto' and m.deleted_at is null
order by g.created_at, g.id
"""


async def pipeline(r: Redis, court_order_id: str, today: date) -> str:
    """Summaries, order intelligence and proposals for one court order whose text is read. Returns done, skipped
    (gone, no text, or nobody auto-tracks it) or later (send it again)."""
    async with db.engine().connect() as c:
        found = await db.rows(c, COURT_ORDER, id=court_order_id)
        if not found or await order_ai.text_state(c, "court_order", court_order_id) != "ready":
            return "skipped"
        orgs = await db.rows(c, TRACKING, cnr=found[0]["cnr"], co=court_order_id)
    if not orgs:
        return "skipped"
    later = False
    for language in sorted({lang for org in orgs for lang in org["languages"]}):
        needing = [o for o in orgs if language in o["languages"]]
        later |= await _automatic(r, "court_order", court_order_id, language, needing) == "later"
    async with db.engine().connect() as c:
        made_on = await order_ai.order_date(c, court_order_id)
    if made_on is None or (today - made_on).days > RECENT_DAYS:
        return "later" if later else "done"
    # ponytail: one language per organisation (its owner's) for proposal titles; per member once tasks are personal.
    event = Event(found[0]["cnr"], "new_order", found[0]["provider_ref"])  # its message's key
    for language in sorted({org["owner_language"] for org in orgs}):
        group = [o for o in orgs if o["owner_language"] == language]
        intel = await _automatic(r, "order_intel", court_order_id, language, group, made_on)
        later |= intel == "later"
        if not isinstance(intel, dict):
            continue
        for org in (o for o in group if o["order_id"]):
            async with db.engine().begin() as c:
                n = await order_ai.propose(c, org["org_id"], org["id"], org["order_id"], court_order_id, intel)
                if n:
                    await notify.new_order(c, org, event, n)
            log.info("order_actions_proposed", court_order_id=court_order_id, org_id=org["org_id"], actions=n)
    return "later" if later else "done"


async def _automatic(
    r: Redis,
    doc: order_ai.Doc,
    court_order_id: str,
    language: order_ai.Language,
    orgs: list[dict[str, Any]],
    made_on: date | None = None,
) -> dict[str, Any] | str:
    """One shared summary or intelligence for `orgs` (those that need it in `language`, oldest first): the stored one,
    or one made on the automatic cap of the first within it. Else later (the platform budget is spent, the model is
    busy, or another run is making the intelligence), skipped (all over their cap, or another run is making the
    summary and will copy it to everyone) or failed."""
    async with db.engine().begin() as c:
        if (hit := await order_ai.cached(c, doc, court_order_id, language)) is not None:
            if doc == "court_order":
                await order_ai.fan_out(c, court_order_id, language, hit)
            return hit
        payer = await _payer(c, orgs)
    if not isinstance(payer, dict):
        return "later" if payer is Automatic.LATER else "skipped"
    org_id, matter_id, connect = payer["org_id"], payer["id"], db.engine().begin
    try:
        if doc == "order_intel" and made_on:
            made = await order_ai.intel(
                connect, r, court_order_id, language, made_on, org_id=org_id, matter_id=matter_id, billing="automatic"
            )
        else:
            made = await order_ai.summarise(
                connect, r, "court_order", court_order_id, language, org_id=org_id, matter_id=matter_id,
                billing="automatic",
            )  # fmt: skip
    except AIError as e:
        run = e.run
        log.warning("order_ai_failed", task=run.task, id=court_order_id, status=run.status, code=run.error_code)
        return "later" if run.status == "unavailable" else "failed"
    if made is None:  # its lock is held
        return "later" if doc == "order_intel" else "skipped"
    return made


async def _payer(c: AsyncConnection, orgs: list[dict[str, Any]]) -> dict[str, Any] | Automatic:
    """The first organisation within its automatic-AI cap; else LATER (a platform-wide budget) or ON_OPEN."""
    for org in orgs:
        decision = await ai.automatic(c, org["org_id"])
        if decision is not Automatic.ON_OPEN:
            return org if decision is Automatic.RUN else decision
    return Automatic.ON_OPEN


@app.task(name=ORDER_AI)
def automatic_order_ai(court_order_id: str, attempt: int = 0) -> str:
    outcome = jobs.run_task(lambda r: pipeline(r, court_order_id, today_ist()))
    if outcome == "later":
        if attempt + 1 < MAX_ATTEMPTS:
            jobs.send(ORDER_AI, court_order_id, attempt=attempt + 1, countdown=RETRY_S)
        else:
            log.warning("order_ai_gave_up", court_order_id=court_order_id, attempts=MAX_ATTEMPTS)
    return outcome


# ---------------------------------------------------------------- on-demand jobs (§10.2)


async def _ready(c: AsyncConnection, kind: order_ai.Kind, source_id: str) -> None:
    match await order_ai.text_state(c, kind, source_id):
        case "pending":
            raise jobs.RetryLater("ORDER_TEXT_PENDING")
        case "unreadable":
            raise jobs.JobFailed("ORDER_TEXT_UNREADABLE")
        case None:
            raise jobs.JobFailed("NOT_FOUND")


async def _order(job: jobs.Job) -> dict[str, Any]:
    """The job's order (its organisation's live orders row) with the court order behind it, text read."""
    async with db.engine().connect() as c:
        found = await db.rows(
            c,
            "select matter_id::text, court_order_id::text from public.orders "
            "where id = cast(:id as uuid) and org_id = cast(:o as uuid) and deleted_at is null",
            id=job.input["order_id"], o=job.org_id,
        )  # fmt: skip
        if not found:
            raise jobs.JobFailed("NOT_FOUND")
        if not found[0]["court_order_id"]:
            raise jobs.JobFailed("ORDER_SUMMARY_UNAVAILABLE")
        await _ready(c, "court_order", found[0]["court_order_id"])
    return found[0]


async def _made(make: Awaitable[dict[str, Any] | None]) -> dict[str, Any]:
    """Await an order_ai call for a job: a busy model or a run in progress retries; a failed run fails the job, and so
    do credits spent since the request (by others accepted with it), before the model is called."""
    try:
        made = await make
    except AIError as e:
        if e.run.status == "unavailable":
            raise jobs.RetryLater("AI_BUSY") from e
        raise jobs.JobFailed("AI_FAILED") from e
    except order_ai.CreditsExhausted as e:
        raise jobs.JobFailed("AI_CREDITS_EXHAUSTED") from e
    if made is None:
        raise jobs.RetryLater("AI_IN_PROGRESS")
    return made


def _credits(job: jobs.Job) -> int:
    return int(job.input.get("credits") or 0)


async def summarise_order_job(job: jobs.Job, r: Redis) -> dict[str, Any]:
    order, language = await _order(job), job.input["language"]
    await _made(
        order_ai.summarise(
            db.engine().begin, r, "court_order", order["court_order_id"], language, org_id=str(job.org_id),
            user_id=job.user_id, matter_id=order["matter_id"], billing="credits", credits=_credits(job),
        )
    )  # fmt: skip
    return {"language": language}


async def summarise_document_job(job: jobs.Job, r: Redis) -> dict[str, Any]:
    document_id, language = job.input["document_id"], job.input["language"]
    async with db.engine().connect() as c:
        found = await db.rows(
            c,
            "select matter_id::text from public.documents where id = cast(:id as uuid) and org_id = cast(:o as uuid)",
            id=document_id, o=job.org_id,
        )  # fmt: skip
        if not found:
            raise jobs.JobFailed("NOT_FOUND")
        await _ready(c, "document", document_id)
    await _made(
        order_ai.summarise(
            db.engine().begin, r, "document", document_id, language, org_id=str(job.org_id), user_id=job.user_id,
            matter_id=found[0]["matter_id"], billing="credits", credits=_credits(job),
        )
    )  # fmt: skip
    return {"language": language}


async def order_intel_job(job: jobs.Job, r: Redis) -> dict[str, Any]:
    order, language = await _order(job), job.input["language"]
    async with db.engine().connect() as c:
        made_on = await order_ai.order_date(c, order["court_order_id"])
    if made_on is None:
        raise jobs.JobFailed("ORDER_DATE_UNKNOWN")
    intel = await _made(
        order_ai.intel(
            db.engine().begin, r, order["court_order_id"], language, made_on, org_id=str(job.org_id),
            user_id=job.user_id, matter_id=order["matter_id"], billing="credits", credits=_credits(job),
        )
    )  # fmt: skip
    async with db.engine().begin() as c:
        n = await order_ai.propose(
            c, str(job.org_id), order["matter_id"], job.input["order_id"], order["court_order_id"], intel
        )
    return {"proposed": n}


@app.task(name=tasks.SUMMARISE_ORDER, bind=True, max_retries=5)
def summarise_order(self: Task, job_id: str) -> None:
    jobs.run_job(self, job_id, summarise_order_job)


@app.task(name=tasks.SUMMARISE_DOCUMENT, bind=True, max_retries=5)
def summarise_document(self: Task, job_id: str) -> None:
    jobs.run_job(self, job_id, summarise_document_job)


@app.task(name=tasks.ORDER_INTEL, bind=True, max_retries=5)
def order_intel(self: Task, job_id: str) -> None:
    jobs.run_job(self, job_id, order_intel_job)
