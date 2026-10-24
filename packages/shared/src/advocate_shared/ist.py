"""India Standard Time (UTC+5:30, no daylight saving): every court day, schedule and cap is in IST (spec §6.3)."""

from datetime import UTC, date, datetime, timedelta, timezone

IST = timezone(timedelta(hours=5, minutes=30), "IST")


def now_ist() -> datetime:
    return datetime.now(UTC).astimezone(IST)


def today_ist() -> date:
    return now_ist().date()
