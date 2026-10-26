"""Team endpoints: invites, join codes, member management (spec §10.2 Team, §15.3, §15.7, F16)."""

import json
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from advocate_api.db import CurrentOrg, engine
from advocate_api.main import create_app
from advocate_api.ratelimit import redis
from advocate_shared.settings import get_settings

from .conftest import Team, auth, make_team, sql

PHONES = {
    "owner": ("919999900012", "owner"),
    "adv": ("919999900013", "advocate"),
    "clerk": ("919999900014", None),
    "out": ("919999900015", None),
}


@pytest.fixture(scope="module")
async def client():
    """The app plus a probe route behind `X-Org-Id`, to see membership checks without other route groups."""
    app = create_app()

    @app.get("/probe/org")
    async def probe(org: CurrentOrg) -> dict:
        return {"role": org.role}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest.fixture(scope="module")
async def signed_up() -> Team:
    return await make_team(PHONES, kind="solo")  # sign-ins are rate limited: once per module


@pytest.fixture
async def team(signed_up: Team) -> Team:
    """Back to the starting line-up: a solo owner with one advocate, no invites, fresh accept limits."""
    o, adv = signed_up.org_id, signed_up.users["adv"]
    await sql("delete from public.invites where org_id = :o", o=o)
    await sql("delete from public.memberships where org_id = :o and role <> 'owner' and user_id <> :a", o=o, a=adv)
    await sql(
        "update public.memberships set role = 'advocate', status = 'active', display_name = 'Adv' "
        "where org_id = :o and user_id = :a",
        o=o, a=adv,
    )  # fmt: skip
    await sql("update public.organizations set kind = 'solo' where id = :o", o=o)
    await redis().delete(*(f"rl:invite-accept:{u}" for u in signed_up.users.values()))
    return signed_up


async def invite(c: AsyncClient, team: Team, **body) -> dict:
    r = await c.post(f"/v1/orgs/{team.org_id}/invites", json=body, headers=auth(team.tokens["owner"]))
    assert r.status_code == 201, r.text
    return r.json()


async def accept(c: AsyncClient, team: Team, who: str, code: str):
    return await c.post(f"/v1/invites/{code}/accept", headers=auth(team.tokens[who]))


def error(r) -> tuple[int, str]:
    return r.status_code, r.json()["error"]["code"]


async def test_phone_invite_accepted_by_clerk(client, team, monkeypatch):
    monkeypatch.setattr(get_settings(), "app_link_base", "https://pairavi.in")
    inv = await invite(client, team, role="clerk", phone="9999900014")
    assert inv["role"] == "clerk" and inv["phone"] == "919999900014"
    assert len(inv["code"]) == 8 and not set(inv["code"]) & set("0O1IL")
    assert inv["link"] == f"https://pairavi.in/join/{inv['code']}"
    expires = datetime.fromisoformat(inv["expires_at"]) - datetime.now(UTC)
    assert timedelta(days=6, hours=23) < expires <= timedelta(days=7)
    assert (await sql("select kind from public.organizations where id = :o", o=team.org_id)) == [{"kind": "chamber"}]

    r = await accept(client, team, "clerk", inv["code"].lower())  # codes are case-insensitive
    assert r.status_code == 200, r.text
    assert r.json() == {"org_id": team.org_id, "role": "clerk"}
    [m] = await sql(
        "select role, status, display_name from public.memberships where org_id = :o and user_id = :u",
        o=team.org_id, u=team.users["clerk"],
    )  # fmt: skip
    assert m == {"role": "clerk", "status": "active", "display_name": "Clerk"}
    assert (await client.get("/probe/org", headers=team.h("clerk"))).json() == {"role": "clerk"}


async def test_code_only_invite_and_invalid_codes(client, team):
    open_inv = await invite(client, team, role="junior")
    assert open_inv["phone"] is None and open_inv["link"] is None
    r = await accept(client, team, "out", open_inv["code"])
    assert r.status_code == 200 and r.json()["role"] == "junior"

    wrong_phone = await invite(client, team, role="clerk", phone="9999900013")
    expired = await invite(client, team, role="clerk")
    await sql("update public.invites set expires_at = now() - interval '1 minute' where id = :i", i=expired["id"])
    for code in (open_inv["code"], wrong_phone["code"], expired["code"], "ZZZZZZZZ"):  # reused, wrong phone, ...
        assert error(await accept(client, team, "clerk", code)) == (404, "INVITE_INVALID")
    assert await sql("select 1 from public.memberships where user_id = :u", u=team.users["clerk"]) == []


async def test_only_the_owner_invites(client, team):
    path = f"/v1/orgs/{team.org_id}/invites"
    r = await client.post(path, json={"role": "clerk"}, headers=auth(team.tokens["adv"]))
    assert error(r) == (403, "ROLE_NOT_ALLOWED")
    assert error(await client.post(path, json={"role": "clerk"}, headers=auth(team.tokens["out"]))) == (
        404,
        "NOT_FOUND",
    )
    owner = auth(team.tokens["owner"])
    for body in (
        {"role": "owner"},
        {"role": "clerk", "phone": "5999900014"},
        {"role": "clerk", "phone": "919999900014"},
    ):
        assert error(await client.post(path, json=body, headers=owner)) == (422, "VALIDATION_ERROR")
    assert await sql("select 1 from public.invites where org_id = :o", o=team.org_id) == []


async def test_already_a_member(client, team):
    inv = await invite(client, team, role="clerk")
    assert error(await accept(client, team, "adv", inv["code"])) == (409, "ALREADY_MEMBER")


async def test_team_limit_counts_members_and_open_invites(client, team):
    member = f"/v1/orgs/{team.org_id}/members/{team.users['adv']}"
    owner = auth(team.tokens["owner"])
    assert (await client.patch(member, json={"status": "removed"}, headers=owner)).status_code == 200
    invites = [await invite(client, team, role="clerk") for _ in range(9)]  # owner + 9 open invites = 10
    r = await client.post(f"/v1/orgs/{team.org_id}/invites", json={"role": "clerk"}, headers=owner)
    assert r.status_code == 409 and r.json()["error"]["code"] == "TEAM_LIMIT"
    assert r.json()["error"]["details"] == {"limit": 10}
    assert error(await client.patch(member, json={"status": "active"}, headers=owner)) == (409, "TEAM_LIMIT")

    await sql("update public.invites set expires_at = now() - interval '1 minute' where id = :i", i=invites[0]["id"])
    r = await client.patch(member, json={"status": "active"}, headers=owner)
    assert r.status_code == 200 and r.json()["status"] == "active"
    actions = await sql(
        "select action from public.audit_log where org_id = :o and entity = 'memberships' order by created_at",
        o=team.org_id,
    )
    assert [a["action"] for a in actions][-2:] == ["member_removed", "member_restored"]


async def test_role_change_is_audited(client, team):
    owner = auth(team.tokens["owner"])
    path = f"/v1/orgs/{team.org_id}/members/{team.users['adv']}"
    r = await client.patch(path, json={"role": "junior", "display_name": "Adv Ji"}, headers=owner)
    assert r.status_code == 200, r.text
    assert r.json() == {"user_id": team.users["adv"], "role": "junior", "status": "active", "display_name": "Adv Ji"}
    rows = await sql(
        "select a.user_id::text, a.meta from public.audit_log a join public.memberships m on m.id = a.entity_id "
        "where a.org_id = :o and a.action = 'role_changed' and m.user_id = :u order by a.created_at",
        o=team.org_id, u=team.users["adv"],
    )  # fmt: skip
    assert rows[-1] == {"user_id": team.users["owner"], "meta": {"from": "advocate", "to": "junior"}}

    own = f"/v1/orgs/{team.org_id}/members/{team.users['owner']}"
    assert error(await client.patch(own, json={"role": "clerk"}, headers=owner)) == (409, "OWNER_LOCKED")
    assert error(await client.patch(path, json={}, headers=owner)) == (422, "VALIDATION_ERROR")
    stranger = f"/v1/orgs/{team.org_id}/members/{team.users['out']}"
    assert error(await client.patch(stranger, json={"role": "clerk"}, headers=owner)) == (404, "NOT_FOUND")
    r = await client.patch(own, json={"role": "clerk"}, headers=auth(team.tokens["adv"]))
    assert error(r) == (403, "ROLE_NOT_ALLOWED")


async def test_removed_member_loses_access(client, team):
    assert (await client.get("/probe/org", headers=team.h("adv"))).status_code == 200
    path = f"/v1/orgs/{team.org_id}/members/{team.users['adv']}"
    r = await client.patch(path, json={"status": "removed"}, headers=auth(team.tokens["owner"]))
    assert r.status_code == 200 and r.json()["status"] == "removed"
    assert error(await client.get(f"/v1/orgs/{team.org_id}", headers=auth(team.tokens["adv"]))) == (404, "NOT_FOUND")
    assert error(await client.get("/probe/org", headers=team.h("adv"))) == (403, "NOT_A_MEMBER")


async def test_accept_is_rate_limited(client, team):
    for _ in range(10):
        assert (await accept(client, team, "out", "ZZZZZZZZ")).status_code == 404
    r = await accept(client, team, "out", "ZZZZZZZZ")
    assert r.status_code == 429 and r.json()["error"]["code"] == "RATE_LIMITED"


async def test_owner_lists_open_invites(client, team, monkeypatch):
    path = f"/v1/orgs/{team.org_id}/invites"
    owner = auth(team.tokens["owner"])
    assert (await client.get(path, headers=owner)).json() == []
    first = await invite(client, team, role="clerk", phone="9999900014")
    monkeypatch.setattr(get_settings(), "app_link_base", "https://pairavi.in")
    second = await invite(client, team, role="junior")
    expired = await invite(client, team, role="clerk")
    accepted = await invite(client, team, role="junior")
    await sql("update public.invites set expires_at = now() - interval '1 minute' where id = :i", i=expired["id"])
    assert (await accept(client, team, "out", accepted["code"])).status_code == 200

    r = await client.get(path, headers=owner)
    assert r.status_code == 200, r.text
    assert [i["id"] for i in r.json()] == [second["id"], first["id"]]  # open ones, newest first
    newest = r.json()[0]
    assert newest["code"] == second["code"] and newest["role"] == "junior" and newest["phone"] is None
    assert newest["link"] == f"https://pairavi.in/join/{second['code']}"
    assert r.json()[1]["phone"] == "919999900014"


async def test_only_the_owner_sees_and_revokes_invites(client, team):
    inv = await invite(client, team, role="clerk")
    path = f"/v1/orgs/{team.org_id}/invites"
    for who, expected in (("adv", (403, "ROLE_NOT_ALLOWED")), ("out", (404, "NOT_FOUND"))):
        headers = auth(team.tokens[who])
        assert error(await client.get(path, headers=headers)) == expected
        assert error(await client.delete(f"{path}/{inv['id']}", headers=headers)) == expected
    assert (await sql("select expires_at > now() as open from public.invites where id = :i", i=inv["id"])) == [
        {"open": True}
    ]


async def test_revoking_an_invite_frees_its_seat(client, team):
    owner = auth(team.tokens["owner"])
    path = f"/v1/orgs/{team.org_id}/invites"
    invites = [await invite(client, team, role="clerk") for _ in range(8)]  # owner + adv + 8 open invites = 10
    assert error(await client.post(path, json={"role": "clerk"}, headers=owner)) == (409, "TEAM_LIMIT")

    r = await client.delete(f"{path}/{invites[0]['id']}", headers=owner)
    assert r.status_code == 204, r.text
    assert error(await accept(client, team, "clerk", invites[0]["code"])) == (404, "INVITE_INVALID")
    assert [i["id"] for i in (await client.get(path, headers=owner)).json()] == [i["id"] for i in invites[:0:-1]]
    assert (await client.post(path, json={"role": "clerk"}, headers=owner)).status_code == 201


async def test_revoke_is_404_for_accepted_expired_or_unknown_invites(client, team):
    owner = auth(team.tokens["owner"])
    path = f"/v1/orgs/{team.org_id}/invites"
    accepted = await invite(client, team, role="junior")
    assert (await accept(client, team, "out", accepted["code"])).status_code == 200
    expired = await invite(client, team, role="clerk")
    await sql("update public.invites set expires_at = now() - interval '1 minute' where id = :i", i=expired["id"])
    revoked = await invite(client, team, role="clerk")
    assert (await client.delete(f"{path}/{revoked['id']}", headers=owner)).status_code == 204
    for invite_id in (accepted["id"], expired["id"], revoked["id"], "00000000-0000-0000-0000-000000000000"):
        assert error(await client.delete(f"{path}/{invite_id}", headers=owner)) == (404, "NOT_FOUND"), invite_id


async def test_revoke_beats_an_accept_already_under_way(client, team):
    """An accept whose transaction began before the revoke, so its now() is earlier than the revoke's, still finds
    the invite expired once the revoke has committed."""
    inv = await invite(client, team, role="clerk")
    async with engine().connect() as c:  # the invitee's accept, as user_db runs it; closing rolls it back
        await c.execute(text("set local role authenticated"))
        await c.execute(
            text("select set_config('request.jwt.claims', :c, true)"),
            {"c": json.dumps({"sub": team.users["clerk"], "role": "authenticated"})},
        )
        r = await client.delete(f"/v1/orgs/{team.org_id}/invites/{inv['id']}", headers=auth(team.tokens["owner"]))
        assert r.status_code == 204, r.text
        with pytest.raises(DBAPIError, match="INVITE_INVALID"):
            await c.execute(text("select public.accept_invite(:c)"), {"c": inv["code"]})
