from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Response
from pydantic import BaseModel, Field
from sqlalchemy import text

from advocate_api.db import UserDb
from advocate_api.errors import ApiError

router = APIRouter(prefix="/v1")


class DeviceIn(BaseModel):
    id: UUID  # generated once on the device and kept in secure storage
    platform: Literal["android", "ios", "windows"]
    push_token: str | None = Field(None, max_length=4096)
    app_version: str | None = Field(None, max_length=50)


class Device(BaseModel):
    id: UUID
    platform: str
    app_version: str | None
    new: bool


@router.post("/devices")
async def register_device(db: UserDb, body: DeviceIn) -> Device:
    row = await db.execute(
        text(
            "insert into public.devices (id, user_id, platform, push_token, app_version) "
            "values (:id, auth.uid(), :p, :t, :v) "
            "on conflict (id) do update set push_token = excluded.push_token, app_version = excluded.app_version, "
            "last_seen_at = now(), revoked_at = null "
            "returning id, platform, app_version, (xmax = 0) as new"
        ),
        {"id": body.id, "p": body.platform, "t": body.push_token, "v": body.app_version},
    )
    device = Device(**row.mappings().one())
    if device.new:
        await db.execute(
            text(
                "insert into public.audit_log (user_id, action, entity, entity_id, meta) "
                "values (auth.uid(), 'new_device', 'devices', :id, jsonb_build_object('platform', cast(:p as text)))"
            ),
            {"id": device.id, "p": device.platform},
        )
    return device


@router.delete("/devices/{device_id}", status_code=204)
async def revoke_device(db: UserDb, device_id: UUID) -> Response:
    result = await db.execute(
        text("update public.devices set revoked_at = now() where id = :id and user_id = auth.uid()"), {"id": device_id}
    )
    if result.rowcount == 0:  # type: ignore[attr-defined]
        raise ApiError(404, "NOT_FOUND", "Device not found")
    return Response(status_code=204)
