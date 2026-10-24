"""Sync leakage tests (spec §9.4): what the local PowerSync service streams to each of six real users.

Needs `just dev` (Supabase + the powersync container). Skips locally when the service is down; fails in CI."""

import json
import os
import re
import time
import uuid
from collections import defaultdict
from pathlib import Path

import httpx
import pytest
import yaml
from sqlalchemy import text

from .conftest import _up, sign_in

PS_URL = "http://127.0.0.1:55380"
ROOT = Path(__file__).parents[3]
PHONES = {
    "owner": "919999900006",
    "advocate": "919999900007",
    "junior": "919999900008",
    "clerk": "919999900009",
    "outsider": "919999900010",
    "removed": "919999900011",
}
NEVER = {  # §9.4 "Never synced" tables that exist so far
    "court_cases", "court_hearings", "court_orders", "cause_list_entries", "provider_calls", "usage_ledger",
    "audit_log", "invites", "devices", "consents", "platform_admins", "feedback",
}  # fmt: skip

if not _up(55380):
    if os.environ.get("CI"):
        pytest.fail("PowerSync is not running on :55380", pytrace=False)
    pytest.skip("PowerSync not running (just dev)", allow_module_level=True)


def synced_tables() -> set[str]:
    config = (ROOT / "infra/powersync/sync-config.yaml").read_text("utf-8")
    return set(re.findall(r"\bFROM (\w+)", config))


def sync(token: str) -> dict[str, dict[str, dict]]:
    """One full download as a fresh device: table -> id -> row, applied in protocol order."""
    rows: dict[tuple[str, str, str], dict] = {}
    body = {"raw_data": True, "client_id": "pytest", "streams": {"include_defaults": True, "subscriptions": []}}
    headers = {"Authorization": f"Bearer {token}"}
    with httpx.stream("POST", f"{PS_URL}/sync/stream", json=body, headers=headers, timeout=30) as r:
        r.raise_for_status()
        for line in r.iter_lines():
            msg = json.loads(line) if line else {}
            if "checkpoint_complete" in msg:
                break
            if bucket := msg.get("data"):
                for op in bucket["data"]:
                    key = (bucket["bucket"], op.get("object_type"), op.get("object_id"))
                    if op["op"] == "PUT":
                        rows[key] = json.loads(op["data"])
                    elif op["op"] == "REMOVE":
                        rows.pop(key, None)
                    elif op["op"] == "CLEAR":
                        rows = {k: v for k, v in rows.items() if k[0] != bucket["bucket"]}
    out: dict[str, dict[str, dict]] = defaultdict(dict)
    for (_, table, row_id), row in rows.items():
        out[table][row_id] = row
    return out


@pytest.fixture(scope="module")
async def world():
    """Chamber A (owner, advocate, junior, clerk, one removed member) and solo B (outsider), with rows that each
    sync rule must let through or hold back. Returns user ids, named row ids and access tokens."""
    from advocate_api.db import engine

    phones = list(PHONES.values())
    async with engine().begin() as c:
        await c.execute(
            text("delete from organizations where owner_id in (select id from auth.users where phone = any(:p))"),
            {"p": phones},
        )
        await c.execute(text("delete from auth.users where phone = any(:p)"), {"p": phones})
    tokens = {who: sign_in(phone) for who, phone in PHONES.items()}

    ids = defaultdict(lambda: str(uuid.uuid4()))
    async with engine().begin() as c:
        users = dict(
            (await c.execute(text("select phone, id::text from auth.users where phone = any(:p)"), {"p": phones})).all()
        )
        u = {who: users[phone] for who, phone in PHONES.items()}
        a, b = ids["org_a"], ids["org_b"]
        p = {"a": a, "b": b, **u, **{k: ids[k] for k in ROWS}}
        for statement in filter(str.strip, FIXTURE.split(";")):
            await c.execute(text(statement), p)
    return u, dict(ids), tokens


ROWS = [
    "m_live", "m_deleted", "m_b", "h_live", "h_deleted", "o_live", "or_adv", "or_jun", "d_live", "d_deleted",
    "dop_adv", "np_adv", "np_jun", "ocl_current", "ocl_old", "be_current", "be_old", "fc_pending", "fc_skipped",
    "fc_added", "c_live", "c_deleted", "c_b", "mc", "n_team", "n_private_adv", "n_private_jun", "n_deleted", "n_b",
    "t_live", "t_deleted", "dl_live", "nt_adv", "nt_adv_old", "nt_jun", "j_adv", "j_adv_old", "j_owner",
]  # fmt: skip

FIXTURE = """
insert into organizations (id, name, kind, owner_id) values
  (:a, 'Sync chamber', 'chamber', :owner), (:b, 'Sync solo', 'solo', :outsider);
insert into memberships (org_id, user_id, role, status) values
  (:a, :advocate, 'advocate', 'active'), (:a, :junior, 'junior', 'active'), (:a, :clerk, 'clerk', 'active'),
  (:a, :removed, 'advocate', 'removed')
on conflict (org_id, user_id) do nothing;
insert into matters (id, org_id, source, tracking, title, deleted_at) values
  (:m_live, :a, 'manual', 'manual', 'A v. B', null), (:m_deleted, :a, 'manual', 'manual', 'Gone', now()),
  (:m_b, :b, 'manual', 'manual', 'Other org', null);
insert into hearings (id, org_id, matter_id, date, source, deleted_at) values
  (:h_live, :a, :m_live, '2026-10-27', 'manual', null), (:h_deleted, :a, :m_live, '2026-10-28', 'manual', now());
insert into orders (id, org_id, matter_id, order_date) values (:o_live, :a, :m_live, '2026-10-20');
insert into order_reads (id, org_id, user_id, order_id) values
  (:or_adv, :a, :advocate, :o_live), (:or_jun, :a, :junior, :o_live);
insert into documents (id, org_id, matter_id, title, deleted_at) values
  (:d_live, :a, :m_live, 'Petition', null), (:d_deleted, :a, :m_live, 'Old draft', now());
insert into document_offline_prefs (id, org_id, user_id, document_id) values (:dop_adv, :a, :advocate, :d_live);
insert into notification_prefs (id, user_id, kind) values
  (:np_adv, :advocate, 'new_order'), (:np_jun, :junior, 'new_order');
insert into org_cause_list_entries (id, org_id, matter_id, list_date, is_current) values
  (:ocl_current, :a, :m_live, '2026-10-27', true), (:ocl_old, :a, :m_live, '2026-09-01', false);
insert into board_entries (id, org_id, matter_id, board_date, is_current) values
  (:be_current, :a, :m_live, '2026-10-27', true), (:be_old, :a, :m_live, '2026-09-01', false);
insert into found_cases (id, org_id, user_id, cnr, confidence, match_reason, source, decision) values
  (:fc_pending, :a, :owner, 'TESTSYNC00000001', 'high', 'enrolment', 'onboarding', 'pending'),
  (:fc_skipped, :a, :owner, 'TESTSYNC00000002', 'low', 'partial_name', 'onboarding', 'skipped'),
  (:fc_added, :a, :owner, 'TESTSYNC00000003', 'high', 'enrolment', 'onboarding', 'added');
insert into clients (id, org_id, name, deleted_at) values
  (:c_live, :a, 'Ramesh', null), (:c_deleted, :a, 'Gone', now()), (:c_b, :b, 'Other org', null);
insert into matter_clients (id, org_id, matter_id, client_id) values (:mc, :a, :m_live, :c_live);
insert into notes (id, org_id, matter_id, author_id, body, visibility, deleted_at) values
  (:n_team, :a, :m_live, :owner, 'team', 'team', null),
  (:n_private_adv, :a, :m_live, :advocate, 'mine', 'private', null),
  (:n_private_jun, :a, :m_live, :junior, 'mine', 'private', null),
  (:n_deleted, :a, :m_live, :owner, 'gone', 'team', now()),
  (:n_b, :b, :m_b, :outsider, 'other org', 'team', null);
insert into tasks (id, org_id, matter_id, title, deleted_at) values
  (:t_live, :a, :m_live, 'File reply', null), (:t_deleted, :a, :m_live, 'Gone', now());
insert into deadlines (id, org_id, matter_id, kind, due_date) values (:dl_live, :a, :m_live, 'filing', '2026-11-01');
insert into notifications (id, org_id, user_id, kind, in_window) values
  (:nt_adv, :a, :advocate, 'new_order', true), (:nt_adv_old, :a, :advocate, 'new_order', false),
  (:nt_jun, :a, :junior, 'new_order', true);
insert into jobs (id, org_id, user_id, kind, is_recent) values
  (:j_adv, :a, :advocate, 'find_cases', true), (:j_adv_old, :a, :advocate, 'find_cases', false),
  (:j_owner, :a, :owner, 'find_cases', true);
insert into court_cases (cnr) values ('TESTSYNC00000001') on conflict do nothing;
"""

ORG_A = {
    "m_live", "h_live", "o_live", "d_live", "ocl_current", "be_current", "fc_pending", "fc_skipped",
    "c_live", "mc", "n_team", "t_live", "dl_live",
}  # fmt: skip
EXPECTED = {
    "owner": ORG_A | {"j_owner"},
    "advocate": ORG_A | {"n_private_adv", "or_adv", "dop_adv", "np_adv", "nt_adv", "j_adv"},
    "junior": ORG_A | {"n_private_jun", "or_jun", "np_jun", "nt_jun"},
    "clerk": ORG_A,
    "outsider": {"m_b", "c_b", "n_b"},
    "removed": set(),
}


@pytest.fixture(scope="module")
def received(world):
    _, ids, tokens = world
    deadline = time.monotonic() + 60
    while ids["m_live"] not in sync(tokens["owner"]).get("matters", {}):  # wait for replication
        assert time.monotonic() < deadline, "PowerSync did not replicate the fixture within 60 s"
        time.sleep(0.5)
    return {who: sync(token) for who, token in tokens.items()}


@pytest.mark.parametrize("who", list(PHONES))
def test_each_actor_gets_exactly_their_rows(world, received, who):
    users, ids, _ = world
    names = {v: k for k, v in ids.items() if k in ROWS}
    got = {names[row_id] for table in received[who].values() for row_id in table if row_id in names}
    assert got == EXPECTED[who]
    assert set(received[who].get("profiles", {})) == {users[who]}


@pytest.mark.parametrize("who", list(PHONES))
def test_organisations_and_members(world, received, who):
    _, ids, _ = world
    orgs = {"owner": {"org_a"}, "advocate": {"org_a"}, "junior": {"org_a"}, "clerk": {"org_a"}, "outsider": {"org_b"}}
    want = {ids[o] for o in orgs.get(who, set())}
    assert set(received[who].get("organizations", {})) == want
    assert {m["org_id"] for m in received[who].get("memberships", {}).values()} == want


@pytest.mark.parametrize("who", list(PHONES))
def test_only_synced_tables_and_reference_data(received, who):
    tables = set(received[who])
    assert tables <= synced_tables()
    assert not tables & NEVER
    assert len(received[who]["courts"]) >= 5  # reference rows reach everyone, members or not


async def test_publication_matches_sync_config():
    from advocate_api.db import engine

    async with engine().connect() as c:
        published = await c.execute(text("select tablename from pg_publication_tables where pubname = 'powersync'"))
        assert set(published.scalars()) == synced_tables()


def test_sync_config_parses():
    config = yaml.safe_load((ROOT / "infra/powersync/sync-config.yaml").read_text("utf-8"))
    assert config["config"]["edition"] == 3
    assert all(s.get("auto_subscribe") for s in config["streams"].values())


async def test_device_schema_matches_database():
    """apps/client/lib/data/sync/schema.dart has every column of every synced table, typed as PowerSync stores it."""
    from advocate_api.db import engine

    dart = (ROOT / "apps/client/lib/data/sync/schema.dart").read_text("utf-8")
    device = {
        table: dict((name, kind) for kind, name in re.findall(r"Column\.(\w+)\('(\w+)'\)", body))
        for table, body in re.findall(r"Table\('(\w+)', \[(.*?)\]\)", dart, re.DOTALL)
    }
    async with engine().connect() as c:
        rows = await c.execute(
            text(
                "select table_name, column_name, data_type from information_schema.columns "
                "where table_schema = 'public' and table_name = any(:t) and column_name <> 'id'"
            ),
            {"t": list(synced_tables())},
        )
        database: dict[str, dict[str, str]] = defaultdict(dict)
        for table, column, data_type in rows:
            database[table][column] = "integer" if data_type in ("boolean", "integer", "bigint") else "text"
    assert device == database


async def test_json_columns_match_database():
    """`jsonColumns` in schema.dart lists exactly the jsonb and array columns, so uploads decode them."""
    from advocate_api.db import engine

    dart = (ROOT / "apps/client/lib/data/sync/schema.dart").read_text("utf-8")
    block = dart[dart.index("const jsonColumns") :]
    pairs = re.findall(r"'(\w+)': \{([^}]*)\}", block)
    listed = {(table, col) for table, cols in pairs for col in re.findall(r"'(\w+)'", cols)}
    async with engine().connect() as c:
        rows = await c.execute(
            text(
                "select table_name, column_name from information_schema.columns where table_schema = 'public' "
                "and table_name = any(:t) and data_type in ('jsonb', 'json', 'ARRAY')"
            ),
            {"t": list(synced_tables())},
        )
        assert listed == {(t, col) for t, col in rows}
