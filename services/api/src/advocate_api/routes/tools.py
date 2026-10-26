"""Text tools (spec §7.1): Kruti Dev and DevLys text to Unicode (F28)."""

import asyncio

from fastapi import APIRouter
from pydantic import BaseModel, Field

from advocate_api.auth import CurrentClaims
from advocate_api.ratelimit import limit
from advocate_shared.krutidev import convert, looks_like_krutidev

router = APIRouter(prefix="/v1/text")


class KrutidevIn(BaseModel):
    text: str = Field(min_length=1, max_length=20_000)  # a few pages; a whole document goes through the pipeline
    devlys: bool = False


class KrutidevOut(BaseModel):
    text: str
    detected: bool  # the input read as Kruti Dev text, so the conversion is likely right


@router.post("/krutidev-to-unicode")
async def krutidev_to_unicode(claims: CurrentClaims, body: KrutidevIn) -> KrutidevOut:
    await limit(f"text:{claims['sub']}", 60, 60)
    return await asyncio.to_thread(  # CPU work on up to 20,000 characters: not on the event loop
        lambda: KrutidevOut(text=convert(body.text, devlys=body.devlys), detected=looks_like_krutidev(body.text))
    )
