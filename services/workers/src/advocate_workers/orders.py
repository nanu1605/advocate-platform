"""The order pipeline (spec §11.5): a new order's PDF is fetched once globally into court-orders/{cnr}/{sha256}.pdf and
recorded on court_orders (storage_path, sha256), the same convention and Redis lock (order-pdf:{id}) as the API's
fetch-on-open. Text, OCR and summaries come in P2. A shared fetch (platform row, §11.8): it pauses at the global daily
cap and skips a CNR whose tracking organisations are all over budget; the API then fetches the PDF when someone opens
it."""

import hashlib
from datetime import date
from uuid import uuid4

import structlog
from redis.asyncio import Redis
from sqlalchemy import text

from advocate_shared.ist import today_ist
from advocate_workers import db, jobs, storage
from advocate_workers.celery_app import ORDER_PIPELINE, app
from advocate_workers.courts import CourtData, Paused, Spend
from court_data.models import Capability, ProviderError

log = structlog.get_logger()

LOCK_TTL_S = 300


async def fetch_order(r: Redis, court_order_id: str, today: date) -> str:
    """Fetch and store one court order's PDF. Returns stored, skipped (already stored, or gone), busy (another fetch
    holds the lock), paused (a budget) or failed.
    ponytail: a failed fetch or upload isn't retried; the API fetches the PDF when someone opens the order."""
    lock, token = f"order-pdf:{court_order_id}", uuid4().hex
    if not await r.set(lock, token, nx=True, ex=LOCK_TTL_S):
        return "busy"
    try:
        async with db.engine().connect() as c:
            found = await db.rows(
                c, "select cnr, provider_ref, storage_path from public.court_orders where id = :id", id=court_order_id
            )
        if not found or found[0]["storage_path"]:
            return "skipped"
        cnr, ref = found[0]["cnr"], found[0]["provider_ref"]
        async with CourtData(r, today) as cd:
            if not await cd.drop_over_budget([cnr]):
                return "paused"
            pdf = await cd.call(Spend.SHARED, Capability.ORDER_PDF, lambda p: p.get_order_pdf(cnr, ref), cnr=cnr)
        sha = hashlib.sha256(pdf).hexdigest()
        path = f"{cnr}/{sha}.pdf"
        await storage.put("court-orders", path, pdf, "application/pdf")
        async with db.engine().begin() as c:
            await c.execute(
                text("update public.court_orders set storage_path = :p, sha256 = :s where id = :id"),
                {"p": path, "s": sha, "id": court_order_id},
            )
        return "stored"
    except Paused:
        return "paused"
    except ProviderError as e:
        log.warning("order_pdf_failed", court_order_id=court_order_id, code=e.code)
        return "failed"
    finally:
        await r.register_script(jobs.RELEASE)(keys=[lock], args=[token])


@app.task(name=ORDER_PIPELINE)
def order_pipeline(court_order_id: str) -> str:
    return jobs.run_task(lambda r: fetch_order(r, court_order_id, today_ist()))
