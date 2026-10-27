"""Celery app and the beat schedule (spec §11.5, IST). Each module registers its own tasks under exactly these names:

    find.py       advocate_shared.tasks.FIND_CASES (job), AUTO_MATCH
    refresh.py    advocate_shared.tasks.FETCH_CASES (job), advocate_shared.tasks.REFRESH_CASE (job),
                  POST_HEARING_REFRESH, POST_HEARING_RETRY (kwarg attempt=1|2), WEEKLY_SWEEP
    orders.py     ORDER_PIPELINE (arg: court_order_id)
    board.py      TODAY_MORNING
    notify.py     DEADLINE_REMINDERS
    causelist.py  CAUSE_LIST_TOMORROW (kwarg attempt=1|2|3), ADVOCATE_WATCH
    scan.py       advocate_shared.tasks.SCAN_DOCUMENT (job)
    text.py       advocate_shared.tasks.EXTRACT_TEXT (args: kind, id), TEXT_SWEEP
    embed.py      EMBED_CHUNKS
    windows.py    REFRESH_WINDOWS
    jobs.py       SWEEP_JOBS
    ai.py         AI_COST_WATCH
    summaries.py  ORDER_AI (arg: court_order_id, kwarg attempt), advocate_shared.tasks.SUMMARISE_ORDER (job),
                  advocate_shared.tasks.SUMMARISE_DOCUMENT (job), advocate_shared.tasks.ORDER_INTEL (job)

Job tasks take one argument, the job id, and run through jobs.run_job. The beat's tasks go to the `scheduled`
queue, text extraction to `text` and order AI to `ai`, each served by its own worker (infra/docker/compose.yml), so
user jobs on the default queue never wait for them."""

from celery import Celery
from celery.schedules import crontab

from advocate_shared import tasks
from advocate_shared.logging import configure_logging
from advocate_shared.settings import get_settings

AUTO_MATCH = "advocate_workers.find.auto_match"
POST_HEARING_REFRESH = "advocate_workers.refresh.post_hearing_refresh"
POST_HEARING_RETRY = "advocate_workers.refresh.post_hearing_retry"
WEEKLY_SWEEP = "advocate_workers.refresh.weekly_sweep"
ORDER_PIPELINE = "advocate_workers.orders.order_pipeline"
TODAY_MORNING = "advocate_workers.board.today_morning"
DEADLINE_REMINDERS = "advocate_workers.notify.deadline_reminders"
CAUSE_LIST_TOMORROW = "advocate_workers.causelist.cause_list_tomorrow"
ADVOCATE_WATCH = "advocate_workers.causelist.advocate_watch"
REFRESH_WINDOWS = "advocate_workers.windows.refresh_windows"
SWEEP_JOBS = "advocate_workers.jobs.sweep_jobs"
AI_COST_WATCH = "advocate_workers.ai.ai_cost_watch"
TEXT_SWEEP = "advocate_workers.text.text_sweep"
EMBED_CHUNKS = "advocate_workers.embed.embed_chunks"
ORDER_AI = "advocate_workers.summaries.order_ai"

MODULES = [
    "jobs", "find", "refresh", "orders", "board", "notify", "causelist", "scan", "windows", "ai", "text", "embed",
    "summaries",
]  # fmt: skip

configure_logging()
app = Celery("advocate_workers", broker=get_settings().redis_url, include=[f"advocate_workers.{m}" for m in MODULES])
app.conf.update(
    timezone="Asia/Kolkata",  # every schedule is IST (spec §6.3)
    enable_utc=False,
    task_acks_late=True,  # tasks are idempotent, so redelivery after a crash is safe
    worker_prefetch_multiplier=1,
    # Redis hands an unacked task out again after this; above text.py's HARD_LIMIT_S, so a long OCR isn't redelivered
    # while it runs. It also delays redelivery of a task lost in a crash by as long.
    broker_transport_options={"visibility_timeout": 4 * 3600},
    beat_schedule={
        "cause-list-tomorrow-1": {
            "task": CAUSE_LIST_TOMORROW,
            "schedule": crontab(hour=18, minute=30),
            "kwargs": {"attempt": 1},
        },
        "cause-list-tomorrow-2": {
            "task": CAUSE_LIST_TOMORROW,
            "schedule": crontab(hour=20, minute=30),
            "kwargs": {"attempt": 2},
        },
        "cause-list-tomorrow-3": {
            "task": CAUSE_LIST_TOMORROW,
            "schedule": crontab(hour=22, minute=0),
            "kwargs": {"attempt": 3},
        },
        "today-morning": {"task": TODAY_MORNING, "schedule": crontab(hour=7, minute=30)},
        "deadline-due": {"task": DEADLINE_REMINDERS, "schedule": crontab(hour=7, minute=30)},
        "post-hearing-refresh": {"task": POST_HEARING_REFRESH, "schedule": crontab(hour=19, minute=30)},
        "post-hearing-retry-1": {
            "task": POST_HEARING_RETRY,
            "schedule": crontab(hour=8, minute=0),
            "kwargs": {"attempt": 1},
        },
        "post-hearing-retry-2": {
            "task": POST_HEARING_RETRY,
            "schedule": crontab(hour=19, minute=30),
            "kwargs": {"attempt": 2},
        },
        "weekly-sweep": {"task": WEEKLY_SWEEP, "schedule": crontab(day_of_week="sun", hour=10, minute=0)},
        "auto-match": {"task": AUTO_MATCH, "schedule": crontab(day_of_week="sun", hour=2, minute=0)},
        "window-flags": {"task": REFRESH_WINDOWS, "schedule": crontab(minute=5)},
        "job-sweeper": {"task": SWEEP_JOBS, "schedule": crontab(minute="*/10")},
        "ai-cost-watch": {"task": AI_COST_WATCH, "schedule": crontab(minute=35)},
        "text-sweep": {"task": TEXT_SWEEP, "schedule": crontab(minute=20)},
        "embed-sweep": {"task": EMBED_CHUNKS, "schedule": crontab(minute="*/15")},
    },
)
app.conf.task_routes = (
    {entry["task"]: {"queue": "scheduled"} for entry in app.conf.beat_schedule.values()}
    | tasks.ROUTES
    | {ORDER_AI: {"queue": "ai"}}
)
