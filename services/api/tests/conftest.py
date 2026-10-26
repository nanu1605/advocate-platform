"""Integration fixtures: real local Supabase (test OTP numbers) + Redis. Skips cleanly when the stack is down."""

import os
import socket
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

import httpx
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text

from advocate_shared.settings import get_settings

# Test numbers from supabase/config.toml. 919999900001/2 are left for manual app testing.
PHONES = {"a": "919999900003", "b": "919999900004", "c": "919999900005"}
LOCAL_ANON_KEY = (  # well-known key of every local Supabase stack, not a secret
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9"
    ".CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
)


def _up(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


if not (_up(55321) and _up(55322) and _up(6379)):
    pytest.skip("local stack not running (just dev)", allow_module_level=True)


@pytest.fixture(scope="session", autouse=True)
async def clean_test_users():
    """Remove what earlier runs left for the test numbers, so every run starts from fresh sign-ups."""
    phones = list(PHONES.values())
    await drop_orgs(phones)
    await sql("delete from auth.users where phone = any(:p)", p=phones)


def sign_in(phone: str) -> str:
    key = os.environ.get("SUPABASE_ANON_KEY", LOCAL_ANON_KEY)
    base = get_settings().supabase_url
    headers = {"apikey": key}
    httpx.post(f"{base}/auth/v1/otp", json={"phone": phone}, headers=headers).raise_for_status()
    r = httpx.post(f"{base}/auth/v1/verify", json={"type": "sms", "phone": phone, "token": "123456"}, headers=headers)
    r.raise_for_status()
    return r.json()["access_token"]


@pytest.fixture(scope="session")
def tokens(clean_test_users) -> dict[str, str]:
    return {k: sign_in(p) for k, p in PHONES.items()}


def auth(token: str, **extra: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", **extra}


@pytest.fixture(scope="session")
async def api():
    from advocate_api.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


async def sql(statement: str, **params: Any) -> list[dict[str, Any]]:
    """One statement as the database owner (bypasses RLS): fixtures and assertions on server-side rows."""
    from advocate_api.db import engine

    async with engine().begin() as c:
        result = await c.execute(text(statement), params)
        return [dict(r) for r in result.mappings()] if result.returns_rows else []


@dataclass
class Team:
    org_id: str
    users: dict[str, str]  # name -> user id
    tokens: dict[str, str]

    def h(self, who: str, **extra: str) -> dict[str, str]:
        """Auth plus X-Org-Id for this team's organisation."""
        return auth(self.tokens[who], **{"X-Org-Id": self.org_id, **extra})


async def drop_orgs(phones: list[str]) -> None:
    """Delete organisations owned by these test numbers with what would outlive them: their cost records (which
    would turn into org-less rows counted against the global daily cap) and their uploaded files."""
    from advocate_api import storage

    owned = "select id from public.organizations where owner_id in (select id from auth.users where phone = any(:p))"
    for org in await sql(owned, p=phones):
        prefix = str(org["id"])
        listed = await storage._call("POST", "/object/list/documents", json={"prefix": prefix, "limit": 1000})
        names = [f"{prefix}/{o['name']}" for o in listed.json()] if listed.status_code == 200 else []
        if names:
            await storage._call("DELETE", "/object/documents", json={"prefixes": names})
    await sql(f"delete from public.provider_calls where org_id in ({owned})", p=phones)
    await sql(f"delete from public.organizations where id in ({owned})", p=phones)


async def make_team(members: Mapping[str, tuple[str, str | None]], *, kind: str = "chamber") -> Team:
    """Fresh users for the given test numbers and one organisation. `members` maps a name to (phone, role);
    role None leaves that user outside the organisation. The member with role 'owner' owns it. Profiles get the
    name (title-cased) as full_name."""
    phones = [phone for phone, _ in members.values()]
    await drop_orgs(phones)
    await sql("delete from auth.users where phone = any(:p)", p=phones)
    tokens = {name: sign_in(phone) for name, (phone, _) in members.items()}
    rows = await sql("select id, phone from auth.users where phone = any(:p)", p=phones)
    ids = {r["phone"]: str(r["id"]) for r in rows}
    users = {name: ids[phone] for name, (phone, _) in members.items()}
    for name, uid in users.items():
        await sql("update public.profiles set full_name = :n where id = :u", n=name.title(), u=uid)
    owner = next(name for name, (_, role) in members.items() if role == "owner")
    org_id = str(uuid.uuid4())
    await sql(
        "insert into public.organizations (id, name, kind, owner_id) values (:id, :n, :k, :o)",
        id=org_id, n=f"{owner.title()} chamber", k=kind, o=users[owner],
    )  # fmt: skip
    for name, (_, role) in members.items():
        if role and role != "owner":
            await sql(
                "insert into public.memberships (org_id, user_id, role, display_name) values (:o, :u, :r, :n)",
                o=org_id, u=users[name], r=role, n=name.title(),
            )  # fmt: skip
    return Team(org_id, users, tokens)


@pytest.fixture
def enqueued(monkeypatch) -> list[tuple[str, ...]]:
    """Celery tasks the request would have sent, as (task name, *args), instead of sending them."""
    calls: list[tuple[str, ...]] = []

    async def fake(task: str, *args: object) -> None:
        calls.append((task, *map(str, args)))

    monkeypatch.setattr("advocate_api.jobs.enqueue", fake)
    return calls
