"""Integration fixtures: real local Supabase (test OTP numbers) + Redis. Skips cleanly when the stack is down."""

import os
import socket

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
    from advocate_api.db import engine

    async with engine().begin() as c:
        phones = list(PHONES.values())
        await c.execute(
            text(
                "delete from public.organizations where owner_id in (select id from auth.users where phone = any(:p))"
            ),
            {"p": phones},
        )
        await c.execute(text("delete from auth.users where phone = any(:p)"), {"p": phones})


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
