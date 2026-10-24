"""Hourly window flags (spec §9.4). Sync streams can't use now(), so devices sync on booleans kept current here:
jobs.is_recent (running, or finished in the last 24 h), notifications.in_window (last 90 days), and is_current on
board_entries and org_cause_list_entries (today onwards). Each statement only clears flags still set, so a rerun
changes nothing and devices see no needless updates."""

import asyncio
from datetime import datetime

from sqlalchemy import text

from advocate_shared.ist import now_ist
from advocate_workers import db
from advocate_workers.celery_app import REFRESH_WINDOWS, app

WINDOWS = {
    "jobs": """
        update public.jobs set is_recent = false
        where is_recent and status in ('done', 'failed', 'cancelled')
          and updated_at < cast(:now as timestamptz) - interval '24 hours'""",
    "notifications": """
        update public.notifications set in_window = false
        where in_window and created_at < cast(:now as timestamptz) - interval '90 days'""",
    "board_entries": "update public.board_entries set is_current = false where is_current and board_date < :today",
    "org_cause_list_entries": """
        update public.org_cause_list_entries set is_current = false where is_current and list_date < :today""",
}


async def refresh(now: datetime) -> dict[str, int]:
    """Clear the flags that fell out of their window as of `now` (IST); returns rows cleared per table."""
    params = {"now": now, "today": now.date()}
    async with db.engine().begin() as c:
        done = {table: await c.execute(text(sql), params) for table, sql in WINDOWS.items()}
    return {table: result.rowcount for table, result in done.items()}  # type: ignore[attr-defined]


@app.task(name=REFRESH_WINDOWS)
def refresh_windows() -> dict[str, int]:
    return asyncio.run(refresh(now_ist()))
