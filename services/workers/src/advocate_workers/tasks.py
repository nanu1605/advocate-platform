import asyncio

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from advocate_shared.settings import get_settings
from advocate_workers.celery_app import app

# Sync streams can't use now(); jobs.is_recent is the time window devices sync on (spec §9.4).
JOBS_RECENT_SQL = """
update public.jobs set is_recent = false
where is_recent and status in ('done', 'failed', 'cancelled') and updated_at < now() - interval '24 hours'
"""


async def _refresh_jobs_recent() -> int:
    # Workers connect with service credentials (bypass RLS) — spec §9.1 write path 3.
    engine = create_async_engine(get_settings().database_url)
    try:
        async with engine.begin() as conn:
            return (await conn.execute(text(JOBS_RECENT_SQL))).rowcount  # type: ignore[attr-defined]
    finally:
        await engine.dispose()


@app.task
def refresh_jobs_recent() -> int:
    return asyncio.run(_refresh_jobs_recent())
