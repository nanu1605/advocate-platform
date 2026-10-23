from typing import Literal
from uuid import UUID, uuid4

from fastapi import APIRouter
from pydantic import BaseModel, Field
from sqlalchemy import text

from advocate_api.db import UserDb
from advocate_api.errors import ApiError

router = APIRouter(prefix="/v1")


class OrgIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    kind: Literal["solo", "chamber"]


class Org(BaseModel):
    id: UUID
    name: str
    kind: str
    owner_id: UUID


@router.post("/orgs", status_code=201)
async def create_org(db: UserDb, body: OrgIn) -> Org:
    # No RETURNING: it would need the SELECT policy (membership) before the on_org_created trigger adds the
    # caller as owner. Insert with our own id, then read it back.
    org_id = uuid4()
    await db.execute(
        text("insert into public.organizations (id, name, kind, owner_id) values (:id, :n, :k, auth.uid())"),
        {"id": org_id, "n": body.name, "k": body.kind},
    )
    org = await get_org(db, org_id)
    await db.execute(
        text(
            "insert into public.audit_log (org_id, user_id, action, entity, entity_id) "
            "values (:o, auth.uid(), 'org_created', 'organizations', :o)"
        ),
        {"o": org.id},
    )
    return org


@router.get("/orgs/{org_id}")
async def get_org(db: UserDb, org_id: UUID) -> Org:
    # RLS returns the row only to members; outsiders get the same 404 as a missing org.
    row = (
        (
            await db.execute(
                text("select id, name, kind, owner_id from public.organizations where id = :o"), {"o": org_id}
            )
        )
        .mappings()
        .one_or_none()
    )
    if row is None:
        raise ApiError(404, "NOT_FOUND", "Organisation not found")
    return Org(**row)
