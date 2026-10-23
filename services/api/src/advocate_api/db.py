import json
from collections.abc import AsyncIterator
from functools import lru_cache
from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from advocate_api.auth import CurrentClaims
from advocate_api.errors import ApiError
from advocate_shared.settings import get_settings


@lru_cache
def engine() -> AsyncEngine:
    return create_async_engine(get_settings().database_url, pool_pre_ping=True)


async def user_db(claims: CurrentClaims) -> AsyncIterator[AsyncConnection]:
    """One transaction per request, running as the calling user so RLS applies to every query (spec §9.3).
    `app.write_path = 'api'` unlocks the API-only write policies."""
    async with engine().begin() as conn:
        await conn.execute(text("set local role authenticated"))
        await conn.execute(
            text("select set_config('request.jwt.claims', :c, true), set_config('app.write_path', 'api', true)"),
            {"c": json.dumps(claims)},
        )
        yield conn


UserDb = Annotated[AsyncConnection, Depends(user_db)]


class OrgContext:
    def __init__(self, org_id: UUID, role: str):
        self.org_id, self.role = org_id, role


async def org_context(db: UserDb, x_org_id: Annotated[UUID, Header()]) -> OrgContext:
    """Organisation from `X-Org-Id`, verified against the caller's active membership on every request."""
    role = (
        await db.execute(
            text(
                "select role from public.memberships where org_id = :o and user_id = auth.uid() and status = 'active'"
            ),
            {"o": x_org_id},
        )
    ).scalar_one_or_none()
    if role is None:
        raise ApiError(403, "NOT_A_MEMBER", "You are not a member of this organisation")
    return OrgContext(x_org_id, role)


CurrentOrg = Annotated[OrgContext, Depends(org_context)]
