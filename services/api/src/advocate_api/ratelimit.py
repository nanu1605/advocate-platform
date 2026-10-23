from functools import lru_cache

from redis.asyncio import Redis

from advocate_shared.settings import get_settings


@lru_cache
def redis() -> Redis:
    return Redis.from_url(get_settings().redis_url)


async def allow(r: Redis, key: str, limit: int, window_s: int) -> bool:
    """Fixed-window counter: True while `key` has been hit at most `limit` times in the current window."""
    n = await r.incr(f"rl:{key}")
    if n == 1:
        await r.expire(f"rl:{key}", window_s)
    return n <= limit
