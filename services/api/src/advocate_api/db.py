import json
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from functools import lru_cache
from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header, Request
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from advocate_api.auth import CurrentClaims
from advocate_api.errors import ApiError
from advocate_shared.settings import get_settings


@lru_cache
def engine() -> AsyncEngine:
    """hide_parameters: a failed statement's error never carries its values (party names, notes; spec §7.2)."""
    return create_async_engine(get_settings().database_url, pool_pre_ping=True, hide_parameters=True)


async def user_db(request: Request, claims: CurrentClaims) -> AsyncIterator[AsyncConnection]:
    """One transaction per request, running as the calling user so RLS applies to every query (spec §9.3).
    `app.write_path = 'api'` unlocks the API-only write policies. Work registered with [after_commit] runs
    once the transaction has committed (e.g. enqueueing a job a worker will read)."""
    request.state.after_commit = []
    async with engine().begin() as conn:
        await conn.execute(text("set local role authenticated"))
        await conn.execute(
            text("select set_config('request.jwt.claims', :c, true), set_config('app.write_path', 'api', true)"),
            {"c": json.dumps(claims)},
        )
        yield conn
    for fn in request.state.after_commit:
        await fn()


# scope="function": commit before the response goes out, so a failed commit is an error response, not a 200.
UserDb = Annotated[AsyncConnection, Depends(user_db, scope="function")]


def after_commit(request: Request, fn: Callable[[], Awaitable[object]]) -> None:
    request.state.after_commit.append(fn)


@asynccontextmanager
async def service_db() -> AsyncIterator[AsyncConnection]:
    """Server-side writes no user may make: provider cost records, the shared court-order cache (spec §9.1 path 3).
    Only after the user's own access has been checked through [UserDb]."""
    async with engine().begin() as conn:
        yield conn


class OrgContext:
    def __init__(self, org_id: UUID, role: str):
        self.org_id, self.role = org_id, role

    def require(self, *roles: str) -> None:
        """Role checks for API-only actions (spec §10.2, §15.3); RLS covers what a role may read."""
        if self.role not in roles:
            raise ApiError(403, "ROLE_NOT_ALLOWED", "Your role can't do this", details={"roles": list(roles)})


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
