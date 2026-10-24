import json
import secrets
from datetime import datetime
from typing import Literal, Self
from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import text

from advocate_api.auth import CurrentClaims
from advocate_api.db import OrgContext, UserDb
from advocate_api.errors import ApiError
from advocate_api.ratelimit import limit
from advocate_shared.settings import get_settings

router = APIRouter(prefix="/v1")

TEAM_LIMIT = 10  # F16: up to 10 members
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I/L

Role = Literal["advocate", "junior", "clerk"]


class InviteIn(BaseModel):
    role: Role
    phone: str | None = Field(None, pattern=r"^[6-9][0-9]{9}$")  # 10-digit Indian mobile


class Invite(BaseModel):
    id: UUID
    code: str
    role: str
    phone: str | None
    expires_at: datetime
    link: str | None


class Accepted(BaseModel):
    org_id: UUID
    role: str


class MemberIn(BaseModel):
    role: Role | None = None
    status: Literal["active", "removed"] | None = None
    display_name: str | None = Field(None, min_length=1, max_length=100)

    @model_validator(mode="after")
    def _not_empty(self) -> Self:
        if not self.model_dump(exclude_none=True):
            raise ValueError("nothing to change")
        return self


class Member(BaseModel):
    user_id: UUID
    role: str
    status: str
    display_name: str | None


async def owned_org(db: UserDb, org_id: UUID) -> str:
    """Owner-only team changes (spec §15.3): 404 for outsiders, 403 for other roles. Locks the organisation row so
    concurrent invites and reactivations can't overshoot the team limit; returns its kind."""
    role = (
        await db.execute(
            text(
                "select role from public.memberships where org_id = :o and user_id = auth.uid() and status = 'active'"
            ),
            {"o": org_id},
        )
    ).scalar_one_or_none()
    if role is None:
        raise ApiError(404, "NOT_FOUND", "Organisation not found")
    OrgContext(org_id, role).require("owner")
    return (
        await db.execute(text("select kind from public.organizations where id = :o for no key update"), {"o": org_id})
    ).scalar_one()


async def check_team_size(db: UserDb, org_id: UUID) -> None:
    """Active members plus open invites stay within the limit once one more is added."""
    size = (
        await db.execute(
            text(
                "select (select count(*) from public.memberships where org_id = :o and status = 'active') "
                "+ (select count(*) from public.invites where org_id = :o and accepted_at is null "
                "and expires_at > now())"
            ),
            {"o": org_id},
        )
    ).scalar_one()
    if size >= TEAM_LIMIT:
        raise ApiError(409, "TEAM_LIMIT", "This team is full", details={"limit": TEAM_LIMIT})


@router.post("/orgs/{org_id}/invites", status_code=201)
async def create_invite(db: UserDb, org_id: UUID, body: InviteIn) -> Invite:
    kind = await owned_org(db, org_id)
    await check_team_size(db, org_id)
    if kind == "solo":
        await db.execute(text("update public.organizations set kind = 'chamber' where id = :o"), {"o": org_id})
    phone = f"91{body.phone}" if body.phone else None
    for _ in range(5):  # 31^8 codes: a collision is already unlikely, five in a row means something else is wrong
        row = (
            (
                await db.execute(
                    text(
                        "insert into public.invites (org_id, phone, role, code, expires_at) "
                        "values (:o, :p, :r, :c, now() + interval '7 days') on conflict (code) do nothing "
                        "returning id, code, role, phone, expires_at"
                    ),
                    {
                        "o": org_id,
                        "p": phone,
                        "r": body.role,
                        "c": "".join(secrets.choice(CODE_ALPHABET) for _ in range(8)),
                    },
                )
            )
            .mappings()
            .one_or_none()
        )
        if row:
            base = get_settings().app_link_base
            return Invite(**row, link=f"{base}/join/{row['code']}" if base else None)
    raise ApiError(500, "INTERNAL", "Something went wrong", retryable=True)


@router.post("/invites/{code}/accept")
async def accept_invite(claims: CurrentClaims, db: UserDb, code: str) -> Accepted:
    await limit(f"invite-accept:{claims['sub']}", 10, 60)
    org_id = (await db.execute(text("select public.accept_invite(:c)"), {"c": code})).scalar_one()
    role = (
        await db.execute(
            text("select role from public.memberships where org_id = :o and user_id = auth.uid()"), {"o": org_id}
        )
    ).scalar_one()
    return Accepted(org_id=org_id, role=role)


@router.patch("/orgs/{org_id}/members/{user_id}")
async def update_member(db: UserDb, org_id: UUID, user_id: UUID, body: MemberIn) -> Member:
    await owned_org(db, org_id)
    old = (
        (
            await db.execute(
                text(
                    "select id, role, status from public.memberships where org_id = :o and user_id = :u "
                    "for no key update"
                ),
                {"o": org_id, "u": user_id},
            )
        )
        .mappings()
        .one_or_none()
    )
    if old is None:
        raise ApiError(404, "NOT_FOUND", "Member not found")
    if old["role"] == "owner":
        raise ApiError(409, "OWNER_LOCKED", "The owner's membership can't be changed")
    if body.status == "active" and old["status"] != "active":
        await check_team_size(db, org_id)
    member = Member(
        **(
            await db.execute(
                text(
                    "update public.memberships set role = coalesce(:r, role), status = coalesce(:s, status), "
                    "display_name = coalesce(:d, display_name) where id = :id "
                    "returning user_id, role, status, display_name"
                ),
                {"r": body.role, "s": body.status, "d": body.display_name, "id": old["id"]},
            )
        )
        .mappings()
        .one()
    )
    audits: list[tuple[str, dict]] = []
    if member.role != old["role"]:
        audits.append(("role_changed", {"from": old["role"], "to": member.role}))
    if member.status != old["status"]:
        audits.append(("member_removed" if member.status == "removed" else "member_restored", {}))
    for action, meta in audits:
        await db.execute(
            text(
                "insert into public.audit_log (org_id, user_id, action, entity, entity_id, meta) "
                "values (:o, auth.uid(), :a, 'memberships', :id, cast(:m as jsonb))"
            ),
            {"o": org_id, "a": action, "id": old["id"], "m": json.dumps(meta)},
        )
    return member
