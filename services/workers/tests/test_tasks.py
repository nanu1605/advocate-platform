import socket
import uuid

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from advocate_shared.settings import get_settings
from advocate_workers.tasks import _refresh_jobs_recent

with socket.socket() as _s:
    _s.settimeout(0.5)
    if _s.connect_ex(("127.0.0.1", 55322)) != 0:
        pytest.skip("local Supabase not running (just dev)", allow_module_level=True)


async def test_jobs_leave_recent_window_after_24h():
    engine = create_async_engine(get_settings().database_url)
    uid = uuid.uuid4()
    async with engine.begin() as c:
        await c.execute(
            text("insert into auth.users (id, aud, role) values (:u, 'authenticated', 'authenticated')"), {"u": uid}
        )
        await c.execute(
            text(
                "insert into public.jobs (user_id, kind, status, updated_at) values "
                "(:u, 'old_done', 'done', now() - interval '25 hours'), "
                "(:u, 'new_done', 'done', now() - interval '1 hour'), "
                "(:u, 'old_running', 'running', now() - interval '25 hours')"
            ),
            {"u": uid},
        )
    try:
        assert await _refresh_jobs_recent() >= 1
        assert await _refresh_jobs_recent() == 0  # idempotent
        async with engine.connect() as c:
            rows = dict(
                (await c.execute(text("select kind, is_recent from public.jobs where user_id = :u"), {"u": uid})).all()
            )
        assert rows == {"old_done": False, "new_done": True, "old_running": True}
    finally:
        async with engine.begin() as c:
            await c.execute(text("delete from auth.users where id = :u"), {"u": uid})
        await engine.dispose()
