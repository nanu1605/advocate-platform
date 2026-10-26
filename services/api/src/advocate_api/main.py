from fastapi import FastAPI
from fastapi.responses import JSONResponse
from sqlalchemy import text

from advocate_api import courts, errors, idempotency
from advocate_api.db import engine
from advocate_api.ratelimit import redis
from advocate_api.routes import account, board, devices, files, hooks, imports, matters, orgs, team, tools
from advocate_shared.logging import configure_logging


def create_app() -> FastAPI:
    configure_logging()
    app = FastAPI(title="advocate_api", version="0.0.0")
    errors.install(app)
    idempotency.install(app)
    courts.install(app)
    routers = (account, orgs, devices, hooks, team, imports, matters, files, board, tools)
    for r in (m.router for m in routers):
        app.include_router(r)

    @app.get("/healthz", include_in_schema=False)
    async def healthz() -> dict:
        return {"ok": True}

    @app.get("/readyz", include_in_schema=False)
    async def readyz() -> JSONResponse:
        checks = {}
        try:
            async with engine().connect() as c:
                await c.execute(text("select 1"))
            checks["db"] = True
        except Exception:
            checks["db"] = False
        try:
            checks["redis"] = bool(await redis().ping())
        except Exception:
            checks["redis"] = False
        return JSONResponse({"ok": all(checks.values()), **checks}, status_code=200 if all(checks.values()) else 503)

    return app


app = create_app()
