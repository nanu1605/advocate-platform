"""Cases (spec §10.2): search, add by CNR or by hand, on-demand refresh, tracking on/off, official portal link and
delete."""

import hashlib
import json
import re
from dataclasses import asdict
from datetime import UTC, date, datetime, timedelta
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Request, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import RowMapping, text

from advocate_api.auth import CurrentClaims
from advocate_api.courts import court_data
from advocate_api.db import CurrentOrg, OrgContext, UserDb, after_commit
from advocate_api.errors import ApiError
from advocate_api.idempotency import IdempotencyKey
from advocate_api.jobs import create_job
from advocate_api.ratelimit import allow, limit, redis
from advocate_shared import tasks
from advocate_shared.ist import today_ist
from court_data.models import Capability, CaseSearchQuery

router = APIRouter(prefix="/v1")

CNR = re.compile(r"[A-Z]{4}[0-9]{12}")
SEARCH_CACHE_TTL_S = 24 * 3600
REFRESH_EVERY_S = 6 * 3600
# DRAFT – VERIFY (docs/legal-verification.md)  # noqa: RUF003
# Official case-status portals by court level. The user opens them; they need a CAPTCHA, so nothing fetches them
# (hard rule 1).
PORTALS = {
    "SC": "https://www.sci.gov.in/",
    "HC": "https://hcservices.ecourts.gov.in/",
    "DC": "https://services.ecourts.gov.in/",
}


class SearchIn(BaseModel):
    party: str | None = Field(None, max_length=200)
    advocate: str | None = Field(None, max_length=200)
    judge: str | None = Field(None, max_length=200)
    text: str | None = Field(None, max_length=200)
    court_ids: list[UUID] = Field(default_factory=list, max_length=50)
    case_type: str | None = Field(None, max_length=50)
    year: int | None = Field(None, ge=1950, le=2100)
    page: int = Field(1, ge=1)
    page_size: int = Field(20, ge=1, le=50)


class AdvocateOut(BaseModel):
    name: str
    side: str


class CaseHitOut(BaseModel):
    cnr: str
    court_code: str | None
    case_type: str | None
    case_number: str | None
    case_year: int | None
    title: str
    status: str
    next_hearing_date: date | None
    petitioners: list[str]
    respondents: list[str]
    advocates: list[AdvocateOut]
    tracked: bool


class SearchOut(BaseModel):
    items: list[CaseHitOut]
    total: int
    page: int
    has_next: bool
    cached: bool
    post_filtered: bool  # case_type/year removed hits from this page, so `total` (the provider's count) overstates
    ignored_court_ids: list[UUID]  # requested courts the provider has no code for


def search_cache_key(q: CaseSearchQuery) -> str:
    """Results are public data: one entry per normalised query, shared by every organisation."""
    norm = {k: v.lower() if isinstance(v, str) else v for k, v in asdict(q).items()}
    return "casesearch:" + hashlib.sha256(json.dumps(norm, sort_keys=True, default=str).encode()).hexdigest()


# No Idempotency-Key: read-only, rate-limited and served from a 24-hour global cache (ADR 0011).
@router.post("/search/cases")
async def search_cases(db: UserDb, org: CurrentOrg, claims: CurrentClaims, body: SearchIn) -> SearchOut:
    """Provider case search (spec §11.7). Names travel in the body, never in the URL."""
    terms = {k: v.strip() for k in ("party", "advocate", "judge", "text") if (v := getattr(body, k)) and v.strip()}
    if not terms:
        raise ApiError(422, "SEARCH_TERMS_REQUIRED", "Enter a party, advocate, judge or search text")
    await limit(f"search:{claims['sub']}", 30, 60)
    cap = (
        await db.execute(
            text("select (value #>> '{}')::int from public.app_config where key = 'beta_case_search_daily_cap'")
        )
    ).scalar_one_or_none()
    if cap is not None and not await allow(redis(), f"search-day:{org.org_id}:{today_ist()}", cap, 2 * 86400):
        raise ApiError(429, "SEARCH_DAILY_CAP", "Today's case searches are used up", details={"limit": cap})
    known: dict[UUID, str] = {}
    if body.court_ids:
        rows = await db.execute(
            text(
                "select id, provider_codes->>'ecourtsindia' from public.courts "
                "where id = any(:ids) and provider_codes->>'ecourtsindia' is not null"
            ),
            {"ids": body.court_ids},
        )
        known = {r[0]: r[1] for r in rows}
    codes = sorted(set(known.values()))
    q = CaseSearchQuery(**terms, court_codes=tuple(codes), page=body.page, page_size=body.page_size)
    r, key = redis(), search_cache_key(q)
    raw, cached = await r.get(key), True
    if raw is None:
        async with court_data(org.org_id) as providers:
            found = await providers.run(Capability.SEARCH, lambda p: p.search_cases(q), org_id=str(org.org_id))
        fields = {"total": found.total, "page": found.page, "has_next": found.has_next}
        raw, cached = json.dumps({"items": [asdict(h) for h in found.items], **fields}, default=str), False
        await r.set(key, raw, ex=SEARCH_CACHE_TTL_S)
    page = json.loads(raw)
    # Case type and year aren't provider filters: they narrow the page we got.
    case_type = (body.case_type or "").strip().lower()
    items = [
        h
        for h in page["items"]
        if (not case_type or (h["case_type"] or "").lower() == case_type)
        and (body.year is None or h["case_year"] == body.year)
    ]
    tracked = set(
        (
            await db.execute(
                text("select cnr from public.matters where org_id = :o and deleted_at is null and cnr = any(:c)"),
                {"o": org.org_id, "c": [h["cnr"] for h in items]},
            )
        ).scalars()
    )
    return SearchOut(
        items=[CaseHitOut(**h, tracked=h["cnr"] in tracked) for h in items],
        total=page["total"],
        page=page["page"],
        has_next=page["has_next"],
        cached=cached,
        post_filtered=len(items) < len(page["items"]),
        ignored_court_ids=[c for c in dict.fromkeys(body.court_ids) if c not in known],
    )


class CnrIn(BaseModel):
    cnr: str = Field(max_length=40)


class Added(BaseModel):
    matter_id: UUID
    created: bool
    job_id: UUID | None


@router.post("/matters/by-cnr")
async def add_by_cnr(idem: IdempotencyKey, db: UserDb, org: CurrentOrg, request: Request, body: CnrIn) -> Added:
    """Track a case by CNR (spec §4.1); a worker fetches its details."""
    cnr = re.sub(r"[\s-]", "", body.cnr).upper()
    if not CNR.fullmatch(cnr):
        raise ApiError(422, "INVALID_CNR", "A CNR is 4 letters and 12 digits")
    # The allowance lock (same key as the matters_allowance trigger) also serialises adds of the same CNR, so a
    # duplicate add sees the first one's matter instead of tripping the limit.
    await db.execute(
        text("select pg_advisory_xact_lock(hashtextextended('allowance:' || :o, 0))"), {"o": str(org.org_id)}
    )
    row = (
        (
            await db.execute(
                text("select id, deleted_at from public.matters where org_id = :o and cnr = :c"),
                {"o": org.org_id, "c": cnr},
            )
        )
        .mappings()
        .one_or_none()
    )
    if row and row["deleted_at"] is None:
        return idem.keep(Added(matter_id=row["id"], created=False, job_id=None))
    # A concurrent add or restore of the same CNR may win: then this one reports the case as already tracked.
    if row:
        matter_id = row["id"]
        restored = await db.execute(
            text(
                "update public.matters set deleted_at = null, tracking = 'auto' "
                "where id = :id and deleted_at is not null returning id"
            ),
            {"id": matter_id},
        )
        if restored.first() is None:
            return idem.keep(Added(matter_id=matter_id, created=False, job_id=None))
    else:
        inserted = (
            await db.execute(
                text(
                    "insert into public.matters (org_id, source, tracking, cnr) values (:o, 'cnr', 'auto', :c) "
                    "on conflict (org_id, cnr) do nothing returning id"
                ),
                {"o": org.org_id, "c": cnr},
            )
        ).scalar_one_or_none()
        if inserted is None:
            existing = (
                await db.execute(
                    text("select id from public.matters where org_id = :o and cnr = :c"), {"o": org.org_id, "c": cnr}
                )
            ).scalar_one()
            return idem.keep(Added(matter_id=existing, created=False, job_id=None))
        matter_id = inserted
    job_id = await create_job(
        db,
        request,
        task=tasks.FETCH_CASES,
        kind="fetch_cases",
        org_id=org.org_id,
        job_input={"matter_ids": [matter_id]},
    )
    return idem.keep(Added(matter_id=matter_id, created=True, job_id=job_id))


class ManualIn(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    title: str = Field(min_length=1, max_length=300)
    court_id: UUID | None = None
    court_name: str | None = Field(None, min_length=1, max_length=200)  # courts outside the `courts` list
    case_type: str | None = Field(None, max_length=50)
    case_number: str | None = Field(None, max_length=50)
    case_year: int | None = Field(None, ge=1950, le=2100)
    our_side: str | None = Field(None, max_length=100)
    file_no: str | None = Field(None, max_length=100)
    next_date: date | None = None


class Matter(BaseModel):
    id: UUID
    cnr: str | None
    court_id: UUID | None
    court_name: str | None
    case_type: str | None
    case_number: str | None
    case_year: int | None
    title: str | None
    our_side: str | None
    file_no: str | None
    status: str
    tracking: str
    source: str
    created_at: datetime


@router.post("/matters/manual", status_code=201)
async def add_manual(db: UserDb, org: CurrentOrg, body: ManualIn) -> Matter:
    """A case the provider doesn't cover (spec §4.1 "Manual case"), kept up to date by hand."""
    if body.court_id is None and body.court_name is None:
        raise ApiError(422, "COURT_REQUIRED", "Choose a court or type its name")
    if (
        body.court_id
        and not (await db.execute(text("select 1 from public.courts where id = :c"), {"c": body.court_id})).first()
    ):
        raise ApiError(422, "UNKNOWN_COURT", "Court not found")
    matter = (
        (
            await db.execute(
                text(
                    "insert into public.matters (org_id, source, tracking, title, court_id, court_name, case_type, "
                    "case_number, case_year, our_side, file_no) values (:o, 'manual', 'manual', :title, :court_id, "
                    ":court_name, :case_type, :case_number, :case_year, :our_side, :file_no) returning id, cnr, "
                    "court_id, court_name, case_type, case_number, case_year, title, our_side, file_no, status, "
                    "tracking, source, created_at"
                ),
                {"o": org.org_id, **body.model_dump(exclude={"next_date"})},
            )
        )
        .mappings()
        .one()
    )
    if body.next_date:
        await db.execute(
            text("insert into public.hearings (org_id, matter_id, date, source) values (:o, :m, :d, 'manual')"),
            {"o": org.org_id, "m": matter["id"], "d": body.next_date},
        )
    return Matter(**matter)


async def load_matter(db: UserDb, org: OrgContext, matter_id: UUID) -> RowMapping:
    row = (
        (
            await db.execute(
                text(
                    "select m.tracking, m.cnr, m.court_fetched_at, c.level from public.matters m "
                    "left join public.courts c on c.id = m.court_id "
                    "where m.id = :id and m.org_id = :o and m.deleted_at is null"
                ),
                {"id": matter_id, "o": org.org_id},
            )
        )
        .mappings()
        .one_or_none()
    )
    if row is None:
        raise ApiError(404, "NOT_FOUND", "Case not found")
    return row


class JobOut(BaseModel):
    job_id: UUID


@router.post("/matters/{matter_id}/refresh", status_code=202)
async def refresh_matter(
    idem: IdempotencyKey, db: UserDb, org: CurrentOrg, request: Request, matter_id: UUID
) -> JobOut:
    """On-demand refresh (spec §11.5): at most one per case per 6 h per organisation."""
    matter = await load_matter(db, org, matter_id)
    if matter["tracking"] == "manual":
        raise ApiError(409, "MANUAL_CASE", "Manual cases are updated by hand")
    if matter["tracking"] == "off":
        raise ApiError(409, "TRACKING_OFF", "Tracking is off for this case")
    # Claimed before the job exists so concurrent refreshes can't both enqueue; a failed request frees it in 120 s.
    r, key = redis(), f"refresh:{org.org_id}:{matter_id}"
    if not await r.set(key, "pending", nx=True, ex=120):
        raise ApiError(
            429,
            "RATE_LIMITED",
            "This case was refreshed recently",
            retryable=True,
            details={"retry_after_s": max(await r.ttl(key), 1)},
        )
    job_id = await create_job(
        db, request, task=tasks.REFRESH_CASE, kind="refresh_case", org_id=org.org_id, job_input={"matter_id": matter_id}
    )
    after_commit(request, lambda: r.set(key, str(job_id), ex=REFRESH_EVERY_S))
    return idem.keep(JobOut(job_id=job_id))


class TrackingIn(BaseModel):
    tracking: Literal["auto", "off"]


class TrackingOut(BaseModel):
    matter_id: UUID
    tracking: str
    job_id: UUID | None


# No Idempotency-Key: setting the value it already has is a no-op, and the fetch is claimed like a refresh.
@router.patch("/matters/{matter_id}")
async def set_tracking(db: UserDb, org: CurrentOrg, request: Request, matter_id: UUID, body: TrackingIn) -> TrackingOut:
    """Tracking on/off from the case page (spec §4.3; ADR 0015 adds it to §10.2): devices can't change `tracking`
    (§9.3), and the matters_allowance trigger checks the tracked-case allowance when it turns on (TRACKED_CASE_LIMIT).
    Turning it on fetches the case as by-cnr does, unless it was fetched or refreshed in the last 6 h."""
    matter = await load_matter(db, org, matter_id)
    if matter["tracking"] == "manual":
        raise ApiError(409, "MANUAL_CASE", "Manual cases are updated by hand")
    if not matter["cnr"]:
        raise ApiError(409, "NO_CNR", "This case has no CNR")
    if matter["tracking"] == body.tracking:
        return TrackingOut(matter_id=matter_id, tracking=body.tracking, job_id=None)
    await db.execute(
        text("update public.matters set tracking = :t where id = :id"), {"t": body.tracking, "id": matter_id}
    )
    job_id = None
    fetched = matter["court_fetched_at"]
    fresh = fetched is not None and datetime.now(UTC) - fetched < timedelta(seconds=REFRESH_EVERY_S)
    r, key = redis(), f"refresh:{org.org_id}:{matter_id}"
    if body.tracking == "auto" and not fresh and await r.set(key, "pending", nx=True, ex=120):
        job_id = await create_job(
            db,
            request,
            task=tasks.FETCH_CASES,
            kind="fetch_cases",
            org_id=org.org_id,
            job_input={"matter_ids": [matter_id]},
        )
        after_commit(request, lambda: r.set(key, str(job_id), ex=REFRESH_EVERY_S))
    return TrackingOut(matter_id=matter_id, tracking=body.tracking, job_id=job_id)


class OfficialLink(BaseModel):
    url: str
    cnr: str
    verified: bool


@router.get("/matters/{matter_id}/official-link")
async def official_link(db: UserDb, org: CurrentOrg, matter_id: UUID) -> OfficialLink:
    """The official portal for the case (spec §4.3), as a link the user opens themselves."""
    matter = await load_matter(db, org, matter_id)
    cnr = matter["cnr"]
    if not cnr:
        raise ApiError(409, "NO_CNR", "This case has no CNR")
    level = matter["level"] or ("HC" if cnr[2:4] == "HC" else "DC")
    return OfficialLink(url=PORTALS.get(level, PORTALS["DC"]), cnr=cnr, verified=False)


@router.delete("/matters/{matter_id}", status_code=204)
async def delete_matter(db: UserDb, org: CurrentOrg, matter_id: UUID) -> Response:
    """Soft-delete a case and everything filed under it (spec §10.2: owners and advocates)."""
    org.require("owner", "advocate")
    await load_matter(db, org, matter_id)  # delete_matter() would act in whichever of the caller's orgs owns it
    await db.execute(text("select public.delete_matter(:id)"), {"id": matter_id})
    return Response(status_code=204)
