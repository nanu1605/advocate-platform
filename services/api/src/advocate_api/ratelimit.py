from functools import lru_cache

from redis.asyncio import Redis

from advocate_api.errors import ApiError
from advocate_shared.settings import get_settings


@lru_cache
def redis() -> Redis:
    return Redis.from_url(get_settings().redis_url)


async def limit(key: str, max_hits: int, window_s: int) -> None:
    """Raise RATE_LIMITED once `key` is hit more than `max_hits` times in the window (spec §10.1)."""
    if not await allow(redis(), key, max_hits, window_s):
        ttl = await redis().ttl(f"rl:{key}")
        raise ApiError(429, "RATE_LIMITED", "Too many requests", retryable=True, details={"retry_after_s": max(ttl, 1)})


async def allow(r: Redis, key: str, limit: int, window_s: int) -> bool:
    """Fixed-window counter: True while `key` has been hit at most `limit` times in the current window."""
    n = await r.incr(f"rl:{key}")
    if n == 1:
        await r.expire(f"rl:{key}", window_s)
    return n <= limit
