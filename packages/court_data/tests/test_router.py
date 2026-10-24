from decimal import Decimal
from typing import Any

import pytest

from court_data.models import Capability, CaseNotFound, ProviderError, SearchPage
from court_data.router import CallRecord, ProviderRouter

DOWN = ProviderError("COURT_PROVIDER_UNAVAILABLE", retryable=True, http_status=503)


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


class Stub:
    """A provider whose `fetch` replays scripted results; exceptions are raised."""

    def __init__(self, name: str, *results: Any, capabilities=frozenset({Capability.CASE_DETAIL})):
        self.name, self.capabilities, self.results, self.calls = name, capabilities, list(results), 0

    def cost_inr(self, op: Capability, n: int = 1) -> Decimal:
        return Decimal("0.50") * n

    async def fetch(self) -> Any:
        self.calls += 1
        r = self.results.pop(0) if len(self.results) > 1 else self.results[0]
        if isinstance(r, Exception):
            raise r
        return r


def router(*providers: Stub, clock: Clock | None = None) -> tuple[ProviderRouter, list[CallRecord]]:
    calls: list[CallRecord] = []
    p: list[Any] = list(providers)
    return ProviderRouter(p, calls.append, clock or Clock()), calls


async def fetch(r: ProviderRouter, op: Capability = Capability.CASE_DETAIL, n: int = 1) -> Any:
    return await r.run(op, lambda p: p.fetch(), n=n, cnr="TEST010000012024", org_id="org-a")  # type: ignore[attr-defined]


async def test_primary_success_records_cost_and_latency():
    clock = Clock()
    primary = Stub("primary", "case")

    async def slow():
        clock.now += 0.25
        return "case"

    primary.fetch = slow  # type: ignore[method-assign]
    r, calls = router(primary, clock=clock)
    assert await fetch(r) == "case"
    assert calls == [
        CallRecord("primary", Capability.CASE_DETAIL, "TEST010000012024", "org-a", Decimal("0.50"), "ok", 200, 250)
    ]


async def test_falls_back_and_charges_only_the_success():
    r, calls = router(Stub("primary", DOWN), Stub("secondary", "case"))
    assert await fetch(r) == "case"
    assert [(c.provider, c.status, c.cost_inr) for c in calls] == [
        ("primary", "COURT_PROVIDER_UNAVAILABLE", 0),
        ("secondary", "ok", Decimal("0.50")),
    ]


async def test_batch_cost_uses_unit_count_and_empty_results_are_free():
    r, calls = router(Stub("primary", ["hit"], [], capabilities=frozenset({Capability.CAUSELIST_CNR_BATCH})))
    await fetch(r, Capability.CAUSELIST_CNR_BATCH, n=40)
    await fetch(r, Capability.CAUSELIST_CNR_BATCH, n=40)
    assert [c.cost_inr for c in calls] == [Decimal("20.00"), 0]
    empty_page = Stub(
        "p", SearchPage(items=(), total=0, page=1, has_next=False), capabilities=frozenset({Capability.SEARCH})
    )
    r, calls = router(empty_page)
    await fetch(r, Capability.SEARCH)
    assert calls[0].cost_inr == 0


async def test_skips_providers_without_the_capability():
    stub_only = Stub("legalkart_stub", "never", capabilities=frozenset())
    r, calls = router(stub_only, Stub("primary", "case"))
    assert await fetch(r) == "case"
    assert stub_only.calls == 0 and [c.provider for c in calls] == ["primary"]


async def test_raises_last_error_when_all_fail():
    r, _ = router(Stub("primary", DOWN), Stub("secondary", CaseNotFound("TEST010000012024")))
    with pytest.raises(CaseNotFound):
        await fetch(r)
    r, _ = router()
    with pytest.raises(ProviderError, match="no provider available"):
        await fetch(r)


async def test_breaker_opens_after_five_failures_for_ten_minutes():
    clock = Clock()
    primary, secondary = Stub("primary", DOWN), Stub("secondary", "case")
    r, _ = router(primary, secondary, clock=clock)
    for _ in range(6):
        await fetch(r)
    assert primary.calls == 5 and r.breakers["primary"].is_open
    clock.now += 599
    await fetch(r)
    assert primary.calls == 5
    clock.now += 1
    primary.results = ["case"]
    await fetch(r)
    assert primary.calls == 6 and not r.breakers["primary"].is_open


async def test_breaker_reopens_when_the_trial_call_fails():
    clock = Clock()
    primary = Stub("primary", DOWN)
    r, _ = router(primary, Stub("secondary", "case"), clock=clock)
    for _ in range(5):
        await fetch(r)
    clock.now += 600
    await fetch(r)
    assert primary.calls == 6 and r.breakers["primary"].is_open


async def test_data_errors_do_not_trip_the_breaker():
    primary = Stub("primary", CaseNotFound("x"))
    r, _ = router(primary, Stub("secondary", "case"))
    for _ in range(6):
        await fetch(r)
    assert primary.calls == 6 and not r.breakers["primary"].is_open
