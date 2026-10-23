import uuid

from httpx import ASGITransport, AsyncClient

from advocate_api.db import CurrentOrg
from advocate_api.main import create_app

from .conftest import auth


async def test_health(api):
    assert (await api.get("/healthz")).json() == {"ok": True}
    ready = await api.get("/readyz")
    assert ready.status_code == 200, ready.json()


async def test_requires_valid_token(api):
    r = await api.get("/v1/me")
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "UNAUTHENTICATED"
    r = await api.get("/v1/me", headers={"Authorization": "Bearer not.a.jwt"})
    assert r.status_code == 401


async def test_profile_created_and_editable(api, tokens):
    me = (await api.get("/v1/me", headers=auth(tokens["a"]))).json()
    assert me["phone"] == "919999900003"
    assert me["preferred_language"] == "hi"
    r = await api.patch("/v1/me", json={"full_name": "राम शर्मा", "preferred_language": "en"}, headers=auth(tokens["a"]))
    assert r.status_code == 200
    assert r.json()["full_name"] == "राम शर्मा"
    assert r.json()["preferred_language"] == "en"
    bad = await api.patch("/v1/me", json={"preferred_language": "fr"}, headers=auth(tokens["a"]))
    assert bad.status_code == 422
    assert bad.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_org_isolation(api, tokens):
    r = await api.post("/v1/orgs", json={"name": "Chamber A", "kind": "chamber"}, headers=auth(tokens["a"]))
    assert r.status_code == 201
    org_id = r.json()["id"]

    me = (await api.get("/v1/me", headers=auth(tokens["a"]))).json()
    assert {"org_id": org_id, "org_name": "Chamber A", "org_kind": "chamber", "role": "owner"} in me["memberships"]

    assert (await api.get(f"/v1/orgs/{org_id}", headers=auth(tokens["a"]))).status_code == 200
    # The API runs as the user, so another organisation's row is invisible — same answer as a missing org.
    outsider = await api.get(f"/v1/orgs/{org_id}", headers=auth(tokens["b"]))
    assert outsider.status_code == 404
    assert (await api.get("/v1/me", headers=auth(tokens["b"]))).json()["memberships"] == []


async def test_org_context_header(tokens):
    app = create_app()

    @app.get("/probe")
    async def probe(org: CurrentOrg) -> dict:
        return {"role": org.role}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        org_id = (await c.post("/v1/orgs", json={"name": "Solo C", "kind": "solo"}, headers=auth(tokens["c"]))).json()[
            "id"
        ]
        assert (await c.get("/probe", headers=auth(tokens["c"], **{"X-Org-Id": org_id}))).json() == {"role": "owner"}
        denied = await c.get("/probe", headers=auth(tokens["b"], **{"X-Org-Id": org_id}))
        assert denied.status_code == 403
        assert denied.json()["error"]["code"] == "NOT_A_MEMBER"
        assert (await c.get("/probe", headers=auth(tokens["c"]))).status_code == 422  # header required


async def test_consents(api, tokens):
    h = auth(tokens["b"])
    missing = await api.post(
        "/v1/consents", json={"version": "v1", "items": [{"purpose": "analytics", "granted": True}]}, headers=h
    )
    assert missing.status_code == 422
    assert missing.json()["error"]["code"] == "CONSENT_REQUIRED"

    items = [{"purpose": "account_processing", "granted": True}, {"purpose": "whatsapp_alerts", "granted": False}]
    r = await api.post("/v1/consents", json={"version": "v1", "items": items}, headers=h)
    assert r.status_code == 201
    # Withdrawal is a new row; the latest decision wins.
    await api.post(
        "/v1/consents", json={"version": "v1", "items": [{"purpose": "whatsapp_alerts", "granted": True}]}, headers=h
    )
    current = {c["purpose"]: c["granted"] for c in (await api.get("/v1/consents", headers=h)).json()}
    assert current == {"account_processing": True, "whatsapp_alerts": True}


async def test_devices(api, tokens):
    device_id = str(uuid.uuid4())
    body = {"id": device_id, "platform": "android", "app_version": "1.0.0"}
    r = await api.post("/v1/devices", json=body, headers=auth(tokens["a"]))
    assert r.status_code == 200, r.text
    assert r.json()["new"] is True
    again = (await api.post("/v1/devices", json=body, headers=auth(tokens["a"]))).json()
    assert again["new"] is False

    hijack = await api.post("/v1/devices", json=body, headers=auth(tokens["b"]))
    assert hijack.status_code == 403

    assert (await api.delete(f"/v1/devices/{device_id}", headers=auth(tokens["b"]))).status_code == 404
    assert (await api.delete(f"/v1/devices/{device_id}", headers=auth(tokens["a"]))).status_code == 204
