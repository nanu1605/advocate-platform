from celery import Celery
from celery.schedules import crontab

from advocate_shared.settings import get_settings

app = Celery("advocate_workers", broker=get_settings().redis_url, include=["advocate_workers.tasks"])
app.conf.update(
    timezone="Asia/Kolkata",  # every schedule is IST (spec §6.3)
    enable_utc=False,
    task_acks_late=True,  # tasks are idempotent, so redelivery after a crash is safe
    worker_prefetch_multiplier=1,
    beat_schedule={
        "jobs-recent-window": {"task": "advocate_workers.tasks.refresh_jobs_recent", "schedule": crontab(minute=5)},
    },
)
