import json
import uuid
from datetime import UTC, datetime

from standardwebhooks.webhooks import Webhook

from advocate_api.ratelimit import redis
from advocate_shared.settings import get_settings


def signed(phone: str, secret: str | None = None) -> tuple[bytes, dict[str, str]]:
    payload = json.dumps({"user": {"phone": phone}, "sms": {"otp": "424242"}}).encode()
    msg_id, now = f"msg_{uuid.uuid4().hex}", datetime.now(UTC)
    sig = Webhook((secret or get_settings().auth_hook_secret).removeprefix("v1,")).sign(msg_id, now, payload.decode())
    return payload, {
        "webhook-id": msg_id,
        "webhook-timestamp": str(int(now.timestamp())),
        "webhook-signature": sig,
        "content-type": "application/json",
    }


async def test_rejects_bad_signature(api):
    payload, headers = signed("910000000001", secret="whsec_" + "A" * 43 + "=")
    r = await api.post("/hooks/send-sms", content=payload, headers=headers)
    assert r.status_code == 401


async def test_otp_limit_three_per_ten_minutes(api):
    phone = f"91{uuid.uuid4().int % 10**10:010d}"
    await redis().delete(f"rl:otp10m:{phone}", f"rl:otp1d:{phone}")
    for _ in range(3):
        payload, headers = signed(phone)
        assert (await api.post("/hooks/send-sms", content=payload, headers=headers)).status_code == 200
    payload, headers = signed(phone)
    r = await api.post("/hooks/send-sms", content=payload, headers=headers)
    assert r.status_code == 429
    assert r.json()["error"]["http_code"] == 429
