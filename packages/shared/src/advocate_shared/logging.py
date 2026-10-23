import logging

import structlog


def configure_logging(level: int = logging.INFO) -> None:
    """JSON logs. Never pass case content or personal data as log fields (spec §7.2)."""
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso", utc=True),
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(level),
    )
