from typing import Protocol

import structlog

from advocate_shared.settings import get_settings

log = structlog.get_logger()


class Messaging(Protocol):
    """Outbound messages. WhatsApp Cloud API (authentication template) and a DLT-registered SMS provider plug in
    here once the founder's accounts exist (spec §13.3, §15.2)."""

    async def send_otp(self, phone: str, code: str) -> None: ...


class LocalMessaging:
    """Local development only: prints the code to the API console instead of sending it."""

    async def send_otp(self, phone: str, code: str) -> None:
        log.info("otp_local_delivery", phone_suffix=phone[-4:], code=code)


class NotConfigured:
    async def send_otp(self, phone: str, code: str) -> None:
        raise RuntimeError("No OTP channel configured (WhatsApp authentication template or DLT SMS)")


def messaging() -> Messaging:
    return LocalMessaging() if get_settings().app_env == "local" else NotConfigured()
