"""Provider routing, circuit breaking and the per-call cost record (spec §11.2, §11.8)."""

import time
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from decimal import Decimal

from court_data.models import Capability, CourtDataProvider, ProviderError, SearchPage


@dataclass(frozen=True, slots=True)
class CallRecord:
    """One `provider_calls` row. Failed and empty responses cost nothing (§11.3 billing terms)."""

    provider: str
    operation: Capability
    cnr: str | None
    org_id: str | None
    cost_inr: Decimal
    status: str  # "ok" or the error code
    http_status: int | None
    latency_ms: int


class CircuitBreaker:
    """Opens after `threshold` consecutive provider-unavailable errors, for `cooldown_s`. After the cooldown one
    call goes through; if it fails too, the breaker opens again."""

    def __init__(self, threshold: int = 5, cooldown_s: float = 600, clock: Callable[[], float] = time.monotonic):
        self._threshold, self._cooldown, self._clock = threshold, cooldown_s, clock
        self._failures = 0
        self._opened_at: float | None = None

    @property
    def is_open(self) -> bool:
        return self._opened_at is not None and self._clock() - self._opened_at < self._cooldown

    def success(self) -> None:
        self._failures, self._opened_at = 0, None

    def failure(self) -> None:
        self._failures += 1
        if self._failures >= self._threshold:
            self._opened_at = self._clock()


class ProviderRouter:
    """Tries providers in priority order for a capability, skipping open breakers, and falls back on any provider
    error. Every attempt is reported to `on_call`; workers write those to `provider_calls` and `usage_ledger`."""

    def __init__(
        self,
        providers: Sequence[CourtDataProvider],
        on_call: Callable[[CallRecord], None] = lambda _: None,
        clock: Callable[[], float] = time.monotonic,
    ):
        self.providers = providers
        self.breakers = {p.name: CircuitBreaker(clock=clock) for p in providers}
        self._on_call, self._clock = on_call, clock

    async def run[T](
        self,
        op: Capability,
        call: Callable[[CourtDataProvider], Awaitable[T]],
        *,
        n: int = 1,
        cnr: str | None = None,
        org_id: str | None = None,
    ) -> T:
        """`n` is the billed unit count: CNRs for batch operations, otherwise 1."""
        last: ProviderError | None = None
        for p in self.providers:
            breaker = self.breakers[p.name]
            if op not in p.capabilities or breaker.is_open:
                continue
            start = self._clock()
            try:
                result = await call(p)
            except ProviderError as e:
                if e.retryable:
                    breaker.failure()
                self._record(p.name, op, cnr, org_id, Decimal(0), e.code, e.http_status, start)
                last = e
                continue
            breaker.success()
            cost = p.cost_inr(op, n) if _billable(result) else Decimal(0)
            self._record(p.name, op, cnr, org_id, cost, "ok", 200, start)
            return result
        raise last or ProviderError("COURT_PROVIDER_UNAVAILABLE", f"no provider available for {op}", retryable=True)

    def _record(
        self,
        provider: str,
        op: Capability,
        cnr: str | None,
        org_id: str | None,
        cost: Decimal,
        status: str,
        http_status: int | None,
        start: float,
    ) -> None:
        latency = int((self._clock() - start) * 1000)
        self._on_call(CallRecord(provider, op, cnr, org_id, cost, status, http_status, latency))


def _billable(result: object) -> bool:
    items = result.items if isinstance(result, SearchPage) else result
    return not (isinstance(items, list | tuple) and not items)
