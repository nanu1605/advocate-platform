"""Spec §17 P1 exit, Team, end to end: the owner invites a clerk by code; the clerk, signed in and already syncing,
accepts and starts receiving the board, documents and cases but no private notes; the owner assigns tomorrow's board
row to the advocate from a device, and it reaches the advocate's Tomorrow's Board.

Device writes go through PostgREST as the app's connector uploads them (applyCrud). Needs `just dev` (Supabase,
PowerSync on :55380); test_sync's guard skips this module when PowerSync is down locally and fails it in CI."""

import json
import time
import uuid
from collections import defaultdict
from collections.abc import Callable, Iterator
from datetime import timedelta
from typing import Any

import httpx

from advocate_shared.ist import today_ist
from advocate_shared.settings import get_settings

from .conftest import LOCAL_ANON_KEY, auth, make_team, sql
from .test_sync import PS_URL, sync, synced_tables

PHONES = {"owner": ("919999900032", "owner"), "adv": ("919999900033", "advocate"), "clerk": ("919999900034", None)}
COURT = "c0000000-0000-0000-0000-000000000005"  # District Court Indore
Tables = dict[str, dict[str, dict]]


def rest(method: str, path: str, token: str, body: dict, prefer: str) -> httpx.Response:
    """A device write through PostgREST, as supabase-dart sends it: the anon key and the user's token."""
    headers = {"apikey": LOCAL_ANON_KEY, "Prefer": prefer, **auth(token)}
    return httpx.request(method, f"{get_settings().supabase_url}/rest/v1/{path}", json=body, headers=headers)


def follow(lines: Iterator[str], rows: dict[tuple[str, str, str], dict], until: Callable[[Tables], Any]) -> Tables:
    """Read on from an open /sync/stream, applying its operations to `rows`, past as many checkpoints as it takes
    for `until` to hold (unlike test_sync.sync, which stops at the first). Fails after 60 s."""
    end = time.monotonic() + 60
    for line in lines:
        msg = json.loads(line) if line else {}
        for op in (bucket := msg.get("data") or {}).get("data", []):
            key = (bucket["bucket"], op.get("object_type"), op.get("object_id"))
            if op["op"] == "PUT":
                rows[key] = json.loads(op["data"])
            elif op["op"] == "REMOVE":
                rows.pop(key, None)
            elif op["op"] == "CLEAR":
                for k in [k for k in rows if k[0] == bucket["bucket"]]:
                    del rows[k]
        if "checkpoint_complete" in msg:
            tables: Tables = defaultdict(dict)
            for (_, table, row_id), row in rows.items():
                tables[table][row_id] = row
            if until(tables):
                return tables
        assert time.monotonic() < end, "the clerk's stream did not get there within 60 s"
    raise AssertionError("the stream ended")


async def test_clerk_joins_by_code_and_an_assignment_reaches_the_advocate(api):
    team = await make_team(PHONES)
    org, adv, clerk = team.org_id, team.users["adv"], team.users["clerk"]
    tomorrow = today_ist() + timedelta(days=1)
    m, be, d = (str(uuid.uuid4()) for _ in range(3))
    await sql(
        "insert into public.matters (id, org_id, source, tracking, title, court_id) "
        "values (:m, :o, 'manual', 'manual', 'Team flow v. State', :c)",
        m=m, o=org, c=COURT,
    )  # fmt: skip
    await sql(
        "insert into public.board_entries (id, org_id, matter_id, board_date, is_current, court_id, court_no, item_no) "
        "values (:be, :o, :m, :d, true, :c, '4', '1')",
        be=be, o=org, m=m, d=tomorrow, c=COURT,
    )  # fmt: skip
    await sql(
        "insert into public.documents (id, org_id, matter_id, title, upload_status) "
        "values (:d, :o, :m, 'Petition', 'ready')",
        d=d, o=org, m=m,
    )  # fmt: skip
    notes = {}
    for name, who, visibility in (("team", "owner", "team"), ("owner", "owner", "private"), ("adv", "adv", "private")):
        notes[name] = str(uuid.uuid4())
        note = {"id": notes[name], "org_id": org, "matter_id": m, "author_id": team.users[who], "body": name,
                "visibility": visibility}  # fmt: skip
        r = rest("POST", "notes", team.tokens[who], note, "resolution=merge-duplicates")
        assert r.status_code == 201, r.text

    body = {"raw_data": True, "client_id": "pytest-clerk", "streams": {"include_defaults": True, "subscriptions": []}}
    headers = auth(team.tokens["clerk"])
    with httpx.stream("POST", f"{PS_URL}/sync/stream", json=body, headers=headers, timeout=30) as stream:
        stream.raise_for_status()
        lines, rows = stream.iter_lines(), {}
        before = follow(lines, rows, lambda _: True)  # signed in, not yet a member: reference data only
        assert len(before["courts"]) >= 5 and not {"matters", "board_entries", "documents", "notes"} & set(before)

        r = await api.post(f"/v1/orgs/{org}/invites", json={"role": "clerk"}, headers=auth(team.tokens["owner"]))
        assert r.status_code == 201, r.text
        r = await api.post(f"/v1/invites/{r.json()['code']}/accept", headers=auth(team.tokens["clerk"]))
        assert r.status_code == 200, r.text
        assert r.json() == {"org_id": org, "role": "clerk"}

        # Assign to (§4.2) from the owner's device; a clerk may read the board but not assign (§15.3).
        path, prefer = f"board_entries?id=eq.{be}", "return=representation"
        r = rest("PATCH", path, team.tokens["owner"], {"assignee_id": adv}, prefer)
        assert r.status_code == 200 and [row["assignee_id"] for row in r.json()] == [adv], r.text
        r = rest("PATCH", path, team.tokens["clerk"], {"assignee_id": clerk}, prefer)
        assert r.status_code == 200 and r.json() == [], r.text
        assert await sql("select assignee_id::text from public.board_entries where id = :be", be=be) == [
            {"assignee_id": adv}
        ]

        got = follow(lines, rows, lambda t: t.get("board_entries", {}).get(be, {}).get("assignee_id") == adv)

    assert m in got["matters"] and d in got["documents"]
    assert set(got["notes"]) == {notes["team"]}  # neither the owner's nor the advocate's private note
    # ponytail: no fee or invoice tables until P3; seed one then and assert the clerk's stream lacks it (§15.3).
    assert set(got) <= synced_tables()

    advocate = sync(team.tokens["adv"])
    entry = advocate["board_entries"][be]  # the columns the advocate's Tomorrow's Board reads
    assert (entry["assignee_id"], entry["board_date"], entry["is_current"]) == (adv, tomorrow.isoformat(), 1)
    assert set(advocate["notes"]) == {notes["team"], notes["adv"]}
