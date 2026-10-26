"""Embeddings for case-file text (spec §12.4): chunks without a vector go to the embedder in batches, oldest first.
Sent after each extraction and every 15 minutes, so chunks left behind by an embedder outage catch up. One run at a
time (the embedder is the bottleneck); a run stops after RUN_S and sends itself again if work is left. Without an
embedder configured it does nothing, and search uses full text alone."""

import time
from uuid import uuid4

import httpx
import structlog
from redis.asyncio import Redis
from sqlalchemy import text

from advocate_shared import embedder
from advocate_workers import db, jobs
from advocate_workers.celery_app import EMBED_CHUNKS, app

log = structlog.get_logger()

BATCH = 16
RUN_S = 600
LOCK = "embed-chunks"
LOCK_TTL_S = RUN_S + 300

PENDING = "select id::text, text from public.document_chunks where embedding is null order by created_at limit :n"
STORE = "update public.document_chunks set embedding = cast(:v as extensions.vector) where id = cast(:id as uuid)"


async def embed_pending(r: Redis, *, run_s: float = RUN_S) -> int:
    """Embed waiting chunks for up to `run_s` seconds. Returns how many."""
    client = embedder.configured()
    if client is None:
        return 0
    token = uuid4().hex
    if not await r.set(LOCK, token, nx=True, ex=LOCK_TTL_S):
        return 0
    done, more = 0, False
    try:
        deadline = time.monotonic() + run_s
        while True:
            async with db.engine().connect() as c:
                rows = await db.rows(c, PENDING, n=BATCH)
            if not rows:
                break
            if time.monotonic() > deadline:
                more = True
                break
            try:
                vectors = await client.embed([row["text"] for row in rows])
            except httpx.HTTPError as e:
                log.warning("embedder_unavailable", error=type(e).__name__)
                break  # the next sweep tries again
            async with db.engine().begin() as c:
                await c.execute(
                    text(STORE),
                    [{"id": row["id"], "v": embedder.vector(v)} for row, v in zip(rows, vectors, strict=True)],
                )
            done += len(rows)
    finally:
        await r.register_script(jobs.RELEASE)(keys=[LOCK], args=[token])
    if more:
        jobs.send(EMBED_CHUNKS)
    if done:
        log.info("chunks_embedded", count=done)
    return done


@app.task(name=EMBED_CHUNKS)
def embed_chunks() -> int:
    return jobs.run_task(embed_pending)
