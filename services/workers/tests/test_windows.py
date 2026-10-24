"""Window flags (spec §9.4): each table's flag clears once its row leaves the window, and a rerun changes nothing."""

from datetime import timedelta

from conftest import Factory, sql

from advocate_shared.ist import now_ist
from advocate_workers import windows


async def test_flags_leave_their_windows_once(make: Factory):
    now = now_ist()
    today = now.date()
    org = await make.org()
    user = org.owner_id
    await sql(
        "insert into public.jobs (user_id, kind, status, updated_at) values "
        "(:u, 'old_done', 'done', cast(:now as timestamptz) - interval '25 hours'), "
        "(:u, 'new_done', 'done', cast(:now as timestamptz) - interval '1 hour'), "
        "(:u, 'old_running', 'running', cast(:now as timestamptz) - interval '25 hours')",
        u=user, now=now,
    )  # fmt: skip
    await sql(
        "insert into public.notifications (org_id, user_id, kind, title, created_at) values "
        "(:o, :u, 'sync_issue', 'old', cast(:now as timestamptz) - interval '91 days'), "
        "(:o, :u, 'sync_issue', 'recent', cast(:now as timestamptz) - interval '89 days')",
        o=org.id, u=user, now=now,
    )  # fmt: skip
    days = {"yesterday": today - timedelta(days=1), "today": today, "tomorrow": today + timedelta(days=1)}
    for name, day in days.items():
        matter = await make.matter(org, title=name)
        await sql(
            "insert into public.board_entries (org_id, board_date, matter_id) values (:o, :d, :m)",
            o=org.id, d=day, m=matter,
        )  # fmt: skip
        await sql(
            "insert into public.org_cause_list_entries (org_id, matter_id, list_date) values (:o, :m, :d)",
            o=org.id, d=day, m=matter,
        )  # fmt: skip

    on_matter = "join public.matters m on m.id = e.matter_id where e.org_id = :o"
    queries = {
        "jobs": "select kind as k, is_recent as f from public.jobs where user_id = :u",
        "notifications": "select title as k, in_window as f from public.notifications where user_id = :u",
        "board": f"select m.title as k, e.is_current as f from public.board_entries e {on_matter}",
        "cause_list": f"select m.title as k, e.is_current as f from public.org_cause_list_entries e {on_matter}",
    }

    async def flags() -> dict[str, dict[str, bool]]:
        return {name: {r["k"]: r["f"] for r in await sql(q, u=user, o=org.id)} for name, q in queries.items()}

    async def board_updated() -> list[object]:
        return [
            r["updated_at"]
            for r in await sql(
                "select updated_at from public.board_entries where org_id = :o order by board_date", o=org.id
            )
        ]

    cleared = await windows.refresh(now)
    assert all(cleared[t] >= 1 for t in windows.WINDOWS)  # others' rows may clear too, never fewer than ours
    expected = {
        "jobs": {"old_done": False, "new_done": True, "old_running": True},
        "notifications": {"old": False, "recent": True},
        "board": {"yesterday": False, "today": True, "tomorrow": True},
        "cause_list": {"yesterday": False, "today": True, "tomorrow": True},
    }
    assert await flags() == expected

    before = await board_updated()
    await windows.refresh(now)  # idempotent: nothing of ours changes, not even updated_at (no needless sync)
    assert await flags() == expected
    assert await board_updated() == before
