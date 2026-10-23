from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from standardwebhooks.webhooks import Webhook, WebhookVerificationError

from advocate_api.messaging import messaging
from advocate_api.ratelimit import allow, redis
from advocate_shared.settings import get_settings

router = APIRouter()


def hook_error(status: int, message: str) -> JSONResponse:
    # Supabase Auth hook error shape; Auth shows `message` to the client.
    return JSONResponse({"error": {"http_code": status, "message": message}}, status_code=status)


@router.post("/hooks/send-sms", include_in_schema=False)
async def send_sms(request: Request) -> JSONResponse:
    """Supabase Auth Send-SMS hook: verify the signature, enforce OTP limits (spec §15.2), deliver the code."""
    raw = await request.body()
    secret = get_settings().auth_hook_secret.removeprefix("v1,")
    try:
        payload = Webhook(secret).verify(raw, dict(request.headers))
    except WebhookVerificationError, ValueError:
        return hook_error(401, "Invalid signature")

    phone, code = payload["user"]["phone"], payload["sms"]["otp"]
    r = redis()
    if not (await allow(r, f"otp10m:{phone}", 3, 600) and await allow(r, f"otp1d:{phone}", 10, 86400)):
        return hook_error(429, "Too many codes requested. Try again later.")
    await messaging().send_otp(phone, code)
    return JSONResponse({})
