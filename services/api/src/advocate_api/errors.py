from typing import Any

import structlog
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import DBAPIError
from starlette.exceptions import HTTPException


class ApiError(Exception):
    """Error with a stable code the app maps to Hindi/English text (spec §10.1)."""

    def __init__(self, status: int, code: str, message: str, *, retryable: bool = False, details: dict | None = None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details or {}


def body(code: str, message: str, retryable: bool = False, details: dict[str, Any] | None = None) -> dict:
    return {"error": {"code": code, "message": message, "retryable": retryable, "details": details or {}}}


log = structlog.get_logger()

# Business-rule errors raised in SQL as P0001 with a stable code as the message (triggers, accept_invite).
DB_RULES = {
    "TRACKED_CASE_LIMIT": (409, "Your plan tracks no more cases"),
    "INVITE_INVALID": (404, "This invite is not valid"),
    "ALREADY_MEMBER": (409, "You are already in this team"),
    "TEAM_LIMIT": (409, "This team is full"),
}

HTTP_CODES = {
    401: "UNAUTHENTICATED",
    403: "FORBIDDEN",
    404: "NOT_FOUND",
    405: "METHOD_NOT_ALLOWED",
    429: "RATE_LIMITED",
}


def install(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api(_: Request, e: ApiError) -> JSONResponse:
        return JSONResponse(body(e.code, e.message, e.retryable, e.details), status_code=e.status)

    @app.exception_handler(HTTPException)
    async def _http(_: Request, e: HTTPException) -> JSONResponse:
        return JSONResponse(body(HTTP_CODES.get(e.status_code, "HTTP_ERROR"), str(e.detail)), status_code=e.status_code)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, e: RequestValidationError) -> JSONResponse:
        fields = [".".join(str(p) for p in err["loc"]) for err in e.errors()]
        return JSONResponse(body("VALIDATION_ERROR", "Invalid request", details={"fields": fields}), status_code=422)

    @app.exception_handler(DBAPIError)
    async def _db(_: Request, e: DBAPIError) -> JSONResponse:
        # 42501 = row-level security / privilege denial. Never echo DB messages: they can contain row data.
        sqlstate = getattr(e.orig, "sqlstate", None)
        if sqlstate == "42501":
            return JSONResponse(body("FORBIDDEN", "Not allowed"), status_code=403)
        cause = e.orig.__cause__ if e.orig else None
        rule = getattr(cause, "message", "") if sqlstate == "P0001" else ""
        if rule in DB_RULES:
            status, message = DB_RULES[rule]
            limit = getattr(cause, "detail", None)
            return JSONResponse(body(rule, message, details={"limit": int(limit)} if limit else {}), status_code=status)
        log.error("db_error", error=type(e.orig).__name__, sqlstate=sqlstate)
        return JSONResponse(body("INTERNAL", "Something went wrong", retryable=True), status_code=500)
