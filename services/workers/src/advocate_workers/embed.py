"""Embeddings for case-file text (spec §12.4): chunks without a vector go to the embedder in batches, oldest first.
Sent after each extraction and every 15 minutes, so chunks left behind by an embedder outage catch up. One run at a
time (the embedder is the bottleneck); a run stops after RUN_S and sends itself again if work is left. Without an
embedder configured it does nothing, and search uses full text alone. A batch the embedder refuses is sent again one
chunk at a time, and a chunk it still refuses is set aside (REJECTED), so it holds up no one else's."""

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
# ponytail: chunk ids the embedder refused, kept for good (chunks are bounded, so it stays tiny); a column if it grows
REJECTED = "embed-rejected"
REFUSED = {400, 413, 422}  # the request's content; any other status (401, 404, 429, 5xx) is the service's

PENDING = """
select id::text, text from public.document_chunks
where embedding is null and id::text <> all(:rejected) order by created_at limit :n
"""
STORE = "update public.document_chunks set embedding = cast(:v as extensions.vector) where id = cast(:id as uuid)"


async def _vectors(r: Redis, client: embedder.Embedder, rows: list[dict]) -> list[tuple[str, list[float]]]:
    """(chunk id, vector) for the rows the embedder takes. A refused batch is sent one chunk at a time; a refused
    chunk goes into REJECTED. Raises httpx.HTTPError when the embedder is down."""
    try:
        vectors = await client.embed([row["text"] for row in rows])
    except httpx.HTTPStatusError as e:
        if e.response.status_code not in REFUSED:
            raise
        if len(rows) > 1:
            return [pair for row in rows for pair in await _vectors(r, client, [row])]
        await r.sadd(REJECTED, rows[0]["id"])  # pyright: ignore[reportGeneralTypeIssues] - the asyncio client
        log.warning("chunk_rejected", chunk_id=rows[0]["id"], status=e.response.status_code)
        return []
    return [(row["id"], v) for row, v in zip(rows, vectors, strict=True)]


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
            rejected = [m.decode() for m in await r.smembers(REJECTED)]  # pyright: ignore[reportGeneralTypeIssues]
            async with db.engine().connect() as c:
                rows = await db.rows(c, PENDING, n=BATCH, rejected=rejected)
            if not rows:
                break
            if time.monotonic() > deadline:
                more = True
                break
            try:
                vectors = await _vectors(r, client, rows)
            except httpx.HTTPError as e:
                log.warning("embedder_unavailable", error=type(e).__name__)
                break  # the next sweep tries again
            if vectors:
                async with db.engine().begin() as c:
                    await c.execute(text(STORE), [{"id": i, "v": embedder.vector(v)} for i, v in vectors])
            done += len(vectors)
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
