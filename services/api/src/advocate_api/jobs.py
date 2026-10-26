"""Background jobs (spec §6.2): a `jobs` row the user's devices sync for progress, plus a Celery task that a worker
runs after the request's transaction commits. Task names are shared with the workers in advocate_shared.tasks."""

import json
from functools import lru_cache
from typing import Any
from uuid import UUID, uuid4

from celery import Celery
from fastapi import Request
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_api.db import after_commit
from advocate_shared import tasks
from advocate_shared.settings import get_settings


@lru_cache
def celery() -> Celery:
    app = Celery("advocate_api", broker=get_settings().redis_url)
    app.conf.task_routes = tasks.ROUTES  # the sender picks the queue
    return app


async def enqueue(task: str, *args: object) -> None:
    """Sends a Celery task; replaced in tests. A job task takes only the job id: workers read everything else from the
    job row, so a redelivered task resumes the same job."""
    celery().send_task(task, args=[str(a) for a in args])


async def create_job(
    db: AsyncConnection, request: Request, *, task: str, kind: str, org_id: UUID | None, job_input: dict[str, Any]
) -> UUID:
    job_id = uuid4()
    await db.execute(
        text(
            "insert into public.jobs (id, org_id, user_id, kind, input) "
            "values (:id, :o, auth.uid(), :k, cast(:i as jsonb))"
        ),
        {"id": job_id, "o": org_id, "k": kind, "i": json.dumps(job_input, default=str)},
    )
    after_commit(request, lambda: enqueue(task, job_id))
    return job_id
