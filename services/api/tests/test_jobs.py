"""The API's Celery app (jobs.py): Celery routes on the sending side, so tasks the API sends go to the queue the
workers serve them on (infra/docker/compose.yml)."""

from advocate_api import jobs
from advocate_shared import tasks


def test_text_extraction_goes_to_the_text_queue():
    router = jobs.celery().amqp.router
    assert router.route({}, tasks.EXTRACT_TEXT)["queue"].name == "text"  # a court order fetched on open
    assert router.route({}, tasks.SCAN_DOCUMENT)["queue"].name == "celery"  # user jobs: the default queue


def test_order_ai_goes_to_the_ai_queue():
    router = jobs.celery().amqp.router
    for name in (tasks.SUMMARISE_ORDER, tasks.SUMMARISE_DOCUMENT, tasks.ORDER_INTEL):
        assert router.route({}, name)["queue"].name == "ai"  # served by worker-ai: a model call holds up no one
