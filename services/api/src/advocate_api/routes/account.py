from typing import Literal
from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel, Field
from sqlalchemy import text

from advocate_api.db import UserDb
from advocate_api.errors import ApiError

router = APIRouter(prefix="/v1")

PROFILE_SQL = (
    "select id, full_name, phone, email, preferred_language, enrolment_no, bar_council_state, practice_court_ids "
    "from public.profiles where id = auth.uid()"
)


class Membership(BaseModel):
    org_id: UUID
    org_name: str
    org_kind: str
    role: str


class Me(BaseModel):
    id: UUID
    full_name: str | None
    phone: str | None
    email: str | None
    preferred_language: str
    enrolment_no: str | None
    bar_council_state: str | None
    practice_court_ids: list[UUID]
    memberships: list[Membership]


class MePatch(BaseModel):
    full_name: str | None = Field(None, max_length=200)
    email: str | None = Field(None, max_length=320)
    preferred_language: Literal["hi", "en"] | None = None
    enrolment_no: str | None = Field(None, max_length=50)
    bar_council_state: str | None = Field(None, max_length=100)
    practice_court_ids: list[UUID] | None = None


async def load_me(db: UserDb) -> Me:
    profile = (await db.execute(text(PROFILE_SQL))).mappings().one()
    rows = await db.execute(
        text(
            "select m.org_id, o.name as org_name, o.kind as org_kind, m.role from public.memberships m "
            "join public.organizations o on o.id = m.org_id where m.user_id = auth.uid() and m.status = 'active' "
            "order by m.created_at"
        )
    )
    return Me(**profile, memberships=[Membership(**r) for r in rows.mappings()])


@router.get("/me")
async def get_me(db: UserDb) -> Me:
    return await load_me(db)


@router.patch("/me")
async def patch_me(db: UserDb, patch: MePatch) -> Me:
    values = patch.model_dump(exclude_unset=True)
    if values:
        # Column names come from the MePatch model, never from the client.
        sets = ", ".join(f"{k} = :{k}" for k in values)
        await db.execute(text(f"update public.profiles set {sets} where id = auth.uid()"), values)  # noqa: S608
    return await load_me(db)


class ConsentItem(BaseModel):
    purpose: Literal["account_processing", "whatsapp_alerts", "analytics"]
    granted: bool


class ConsentIn(BaseModel):
    version: str = Field(max_length=20)
    items: list[ConsentItem] = Field(min_length=1)


class ConsentOut(BaseModel):
    purpose: str
    version: str
    granted: bool


@router.post("/consents", status_code=201)
async def post_consents(db: UserDb, body: ConsentIn) -> list[ConsentOut]:
    if not any(i.purpose == "account_processing" and i.granted for i in body.items):
        current = await get_consents(db)
        if not any(c.purpose == "account_processing" and c.granted for c in current):
            raise ApiError(422, "CONSENT_REQUIRED", "Account and case processing consent is required")
    await db.execute(
        text("insert into public.consents (user_id, purpose, version, granted) values (auth.uid(), :p, :v, :g)"),
        [{"p": i.purpose, "v": body.version, "g": i.granted} for i in body.items],
    )
    return await get_consents(db)


@router.get("/consents")
async def get_consents(db: UserDb) -> list[ConsentOut]:
    """Latest decision per purpose. Withdrawal is a new row with granted = false."""
    rows = await db.execute(
        text(
            "select distinct on (purpose) purpose, version, granted from public.consents "
            "where user_id = auth.uid() order by purpose, created_at desc"
        )
    )
    return [ConsentOut(**r) for r in rows.mappings()]
