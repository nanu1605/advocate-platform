"""Postgres and Redis for workers. Workers write with service credentials (bypass RLS, spec §9.1 write path 3)."""

from functools import lru_cache
from typing import Any

from redis.asyncio import Redis
from sqlalchemy import NullPool, text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from advocate_shared.settings import get_settings


@lru_cache
def engine() -> AsyncEngine:
    """One engine per process. NullPool: every Celery task runs its own event loop (asyncio.run), and a pooled
    asyncpg connection can't move between loops. hide_parameters: a failed statement's error (logged, later sent to
    Sentry) never carries its values, which can be party names or notification text (§7.2)."""
    return create_async_engine(get_settings().database_url, poolclass=NullPool, hide_parameters=True)


def redis() -> Redis:
    """A new client for one task run (locks, alert markers); the caller closes it."""
    return Redis.from_url(get_settings().redis_url)


async def rows(conn: AsyncConnection, statement: str, **params: Any) -> list[dict[str, Any]]:
    result = await conn.execute(text(statement), params)
    return [dict(r) for r in result.mappings()]
