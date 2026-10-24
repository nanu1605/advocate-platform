"""`Idempotency-Key` for POSTs that create a job, spend money or send a message (spec §10.1).

The first request with a key runs and its response is kept for 24 h; a retry with the same key gets that response
back without running again. A retry while the first is still running gets 409.

Declare `idem: Idem` **before** `db: UserDb` in the handler, so the response is stored only after the transaction
commits (dependencies close in reverse order)."""

import json
from collections.abc import AsyncIterator
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, Request
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse

from advocate_api.auth import CurrentClaims
from advocate_api.errors import ApiError
from advocate_api.ratelimit import redis

TTL_S = 24 * 3600
RUNNING = "running"
RUNNING_TTL_S = 120  # a crashed request frees its key after this


class Replay(Exception):
    def __init__(self, status: int, body: Any):
        self.status, self.body = status, body


class Idem:
    """The handler returns `idem.keep(result)`; a replay sends that body with the route's status code."""

    def __init__(self, status: int) -> None:
        self.status = status
        self.body: Any = None

    def keep[T](self, body: T) -> T:
        self.body = jsonable_encoder(body)
        return body


async def idempotency(
    request: Request,
    claims: CurrentClaims,
    key: Annotated[str, Header(alias="Idempotency-Key", min_length=8, max_length=200)],
) -> AsyncIterator[Idem]:
    r = redis()
    slot = f"idem:{claims['sub']}:{request.method}:{request.url.path}:{key}"
    if not await r.set(slot, RUNNING, nx=True, ex=RUNNING_TTL_S):
        stored = await r.get(slot)
        if stored is None or stored.decode() == RUNNING:
            raise ApiError(409, "IDEMPOTENCY_IN_PROGRESS", "The same request is still running", retryable=True)
        saved = json.loads(stored)
        raise Replay(saved["status"], saved["body"])
    idem = Idem(getattr(request.scope.get("route"), "status_code", None) or 200)
    try:
        yield idem
    except BaseException:
        await r.delete(slot)  # failed requests can be retried with the same key
        raise
    await r.set(slot, json.dumps({"status": idem.status, "body": idem.body}), ex=TTL_S)


IdempotencyKey = Annotated[Idem, Depends(idempotency, scope="function")]


def install(app: FastAPI) -> None:
    @app.exception_handler(Replay)
    async def _replay(_: Request, e: Replay) -> JSONResponse:
        return JSONResponse(e.body, status_code=e.status, headers={"Idempotent-Replay": "true"})
