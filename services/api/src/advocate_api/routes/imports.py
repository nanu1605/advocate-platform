"""Onboarding import and jobs (spec §4.1, §10.2, §11.4)."""

from datetime import datetime
from typing import Any, Literal, Self
from uuid import UUID

from fastapi import APIRouter, Request
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_api.auth import CurrentClaims
from advocate_api.db import CurrentOrg, UserDb
from advocate_api.errors import DB_RULES, ApiError
from advocate_api.idempotency import IdempotencyKey
from advocate_api.jobs import create_job
from advocate_api.ratelimit import limit
from advocate_shared import tasks

router = APIRouter(prefix="/v1")


class JobStarted(BaseModel):
    job_id: UUID
    status: str


class Job(BaseModel):
    id: UUID
    kind: str
    status: str
    progress: dict[str, Any]
    result: dict[str, Any] | None
    error: str | None
    created_at: datetime
    updated_at: datetime


class AddFilter(BaseModel):
    court_id: UUID | None = None
    case_year: int | None = Field(default=None, ge=1900, le=2100)
    confidence: Literal["high", "low"] | None = None


class AddIn(BaseModel):
    """Either `{ids: [...]}` or `{all: true, filter?: {...}}`."""

    ids: list[UUID] | None = Field(default=None, min_length=1, max_length=500)
    all: Literal[True] | None = None
    filter: AddFilter | None = None

    @model_validator(mode="after")
    def one_form(self) -> Self:
        if (self.ids is None) == (self.all is None) or (self.filter is not None and self.all is None):
            raise ValueError("send either ids, or all with an optional filter")
        return self


class AddResult(BaseModel):
    added: int
    already_tracked: int
    matter_ids: list[UUID]
    job_id: UUID | None


class DecisionIn(BaseModel):
    decision: Literal["skipped", "not_mine", "pending"]  # "added" goes through /found-cases/add


class Decision(BaseModel):
    id: UUID
    decision: str


@router.post("/onboarding/find-cases", status_code=202)
async def find_cases(
    idem: IdempotencyKey, db: UserDb, org: CurrentOrg, claims: CurrentClaims, request: Request
) -> JobStarted:
    """Search the courts for the caller's cases (§11.4); found cases land in the X-Org-Id organisation."""
    me = (
        (
            await db.execute(
                text(
                    "select full_name, enrolment_no, bar_council_state, practice_court_ids "
                    "from public.profiles where id = auth.uid()"
                )
            )
        )
        .mappings()
        .one()
    )
    missing = [k for k in ("full_name", "enrolment_no", "bar_council_state") if not (me[k] or "").strip()]
    if missing:
        raise ApiError(422, "PROFILE_INCOMPLETE", "Add your Bar Council details first", details={"missing": missing})
    # One search per user and organisation at a time; the lock stops two devices starting two paid searches.
    await db.execute(
        text("select pg_advisory_xact_lock(hashtextextended('find_cases:' || auth.uid() || :o, 0))"),
        {"o": str(org.org_id)},
    )
    running = (
        (
            await db.execute(
                text(
                    "select id, status from public.jobs where user_id = auth.uid() and org_id = :o "
                    "and kind = 'find_cases' and status in ('queued', 'running') order by created_at desc limit 1"
                ),
                {"o": org.org_id},
            )
        )
        .mappings()
        .one_or_none()
    )
    if running:
        return idem.keep(JobStarted(job_id=running["id"], status=running["status"]))
    await limit(f"find-cases:{claims['sub']}", 3, 86400)  # each search is up to 27 paid provider calls
    job_id = await create_job(
        db,
        request,
        task=tasks.FIND_CASES,
        kind="find_cases",
        org_id=org.org_id,
        job_input={
            "advocate_name": me["full_name"],
            "enrolment_no": me["enrolment_no"],
            "bar_council_state": me["bar_council_state"],
            "practice_court_ids": me["practice_court_ids"],
        },
    )
    return idem.keep(JobStarted(job_id=job_id, status="queued"))


async def _job(db: AsyncConnection, job_id: UUID) -> Job:
    row = (
        (
            await db.execute(
                text(
                    "select id, kind, status, progress, result, error, created_at, updated_at "
                    "from public.jobs where id = :id"
                ),
                {"id": job_id},
            )
        )
        .mappings()
        .one_or_none()
    )
    if row is None:
        raise ApiError(404, "NOT_FOUND", "Job not found")
    return Job(**row)


@router.get("/jobs/{job_id}")
async def get_job(db: UserDb, job_id: UUID) -> Job:
    # RLS: the job's user, or the organisation's owner.
    return await _job(db, job_id)


@router.post("/jobs/{job_id}/cancel")
async def cancel_job(db: UserDb, job_id: UUID) -> Job:
    """Workers see the status and stop; results so far are kept (§11.4)."""
    mine = (
        await db.execute(text("select user_id = auth.uid() from public.jobs where id = :id"), {"id": job_id})
    ).scalar_one_or_none()
    if mine is None:
        raise ApiError(404, "NOT_FOUND", "Job not found")
    if not mine:
        raise ApiError(403, "ROLE_NOT_ALLOWED", "Only the job's user can cancel it")
    result = await db.execute(
        text("update public.jobs set status = 'cancelled' where id = :id and status in ('queued', 'running')"),
        {"id": job_id},
    )
    job = await _job(db, job_id)
    if result.rowcount == 0:  # type: ignore[attr-defined]
        raise ApiError(409, "JOB_FINISHED", "This job has already finished", details={"status": job.status})
    return job


@router.post("/found-cases/add")
async def add_found_cases(
    idem: IdempotencyKey, db: UserDb, org: CurrentOrg, request: Request, body: AddIn
) -> AddResult:
    """Track found cases (§4.1). "Add all" and "Add selected" differ only in how the selection is made."""
    f = body.filter or AddFilter()
    # Candidates are pending or skipped found cases; "all" means pending cases only (disposed ones are ticked
    # one by one). Ids that are no longer candidates (added, not mine, another org) are ignored.
    selected = (
        (
            await db.execute(
                text(
                    "select id, cnr from public.found_cases "
                    "where org_id = :o and decision in ('pending', 'skipped') "
                    "and (cast(:ids as uuid[]) is null or id = any(cast(:ids as uuid[]))) "
                    "and (cast(:ids as uuid[]) is not null or case_status = 'pending') "
                    "and (cast(:court as uuid) is null or court_id = cast(:court as uuid)) "
                    "and (cast(:year as int) is null or case_year = cast(:year as int)) "
                    "and (cast(:conf as text) is null or confidence = cast(:conf as text)) "
                    "order by cnr for update"
                ),
                {"o": org.org_id, "ids": body.ids, "court": f.court_id, "year": f.case_year, "conf": f.confidence},
            )
        )
        .mappings()
        .all()
    )
    selected_ids = [r["id"] for r in selected]
    existing = (
        (
            await db.execute(
                text(
                    "select cnr, deleted_at is not null as deleted from public.matters "
                    "where org_id = :o and cnr = any(cast(:c as text[]))"
                ),
                {"o": org.org_id, "c": [r["cnr"] for r in selected]},
            )
        )
        .mappings()
        .all()
    )
    tracked = {m["cnr"] for m in existing}
    new_ids = [r["id"] for r in selected if r["cnr"] not in tracked]
    restore = [m["cnr"] for m in existing if m["deleted"]]

    if new_ids or restore:
        # Same lock as the matters_allowance trigger, so concurrent adds can't both pass this check.
        await db.execute(
            text("select pg_advisory_xact_lock(hashtextextended('allowance:' || :o, 0))"), {"o": str(org.org_id)}
        )
        cap, used = (
            await db.execute(
                text(
                    "select (select (value #>> '{}')::int from public.app_config "
                    "where key = 'beta_tracked_case_allowance'), "
                    "(select count(*) from public.matters "
                    "where org_id = :o and tracking = 'auto' and deleted_at is null)"
                ),
                {"o": org.org_id},
            )
        ).one()
        if cap is not None and used + len(new_ids) + len(restore) > cap:
            raise ApiError(
                409,
                "TRACKED_CASE_LIMIT",
                DB_RULES["TRACKED_CASE_LIMIT"][1],
                details={"limit": cap, "remaining": max(cap - used, 0)},
            )

    # Court fields can only be written by workers once a matter exists (matters_guard), so a restore only
    # undeletes and re-tracks; the fetch job brings the rest up to date.
    restored = (
        (
            await db.execute(
                text(
                    "update public.matters set deleted_at = null, tracking = 'auto' "
                    "where org_id = :o and cnr = any(cast(:c as text[])) returning id"
                ),
                {"o": org.org_id, "c": restore},
            )
        )
        .scalars()
        .all()
    )
    inserted = (
        (
            await db.execute(
                text(
                    "insert into public.matters (org_id, source, tracking, cnr, court_id, case_type, case_number, "
                    "case_year, title, court_no, next_hearing_date, court_status) "
                    "select org_id, 'found', 'auto', cnr, court_id, case_type, case_number, case_year, title, "
                    "court_no, next_date, case_status from public.found_cases where id = any(cast(:ids as uuid[])) "
                    "returning id"
                ),
                {"ids": new_ids},
            )
        )
        .scalars()
        .all()
    )
    await db.execute(
        text("update public.found_cases set decision = 'added' where id = any(cast(:ids as uuid[]))"),
        {"ids": selected_ids},
    )
    matter_ids = [*restored, *inserted]
    job_id = None
    if matter_ids:
        job_id = await create_job(
            db,
            request,
            task=tasks.FETCH_CASES,
            kind="fetch_cases",
            org_id=org.org_id,
            job_input={"matter_ids": matter_ids},
        )
    result = AddResult(
        added=len(matter_ids), already_tracked=len(tracked) - len(restore), matter_ids=matter_ids, job_id=job_id
    )
    return idem.keep(result)


@router.post("/found-cases/{found_case_id}/decision")
async def decide_found_case(db: UserDb, org: CurrentOrg, found_case_id: UUID, body: DecisionIn) -> Decision:
    params = {"d": body.decision, "id": found_case_id, "o": org.org_id}
    row = (
        (
            await db.execute(
                text(
                    # An added case stays added while its matter is live; once deleted, it can be decided again.
                    "update public.found_cases f set decision = :d where f.id = :id and f.org_id = :o "
                    "and (f.decision <> 'added' or not exists (select 1 from public.matters m "
                    "where m.org_id = f.org_id and m.cnr = f.cnr and m.deleted_at is null)) returning f.id, f.decision"
                ),
                params,
            )
        )
        .mappings()
        .one_or_none()
    )
    if row is None:
        exists = (
            await db.execute(text("select 1 from public.found_cases where id = :id and org_id = :o"), params)
        ).scalar_one_or_none()
        if exists:
            raise ApiError(409, "FOUND_CASE_ADDED", "This case is already tracked")
        raise ApiError(404, "NOT_FOUND", "Found case not found")
    return Decision(**row)
