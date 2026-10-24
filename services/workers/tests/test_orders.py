"""The order pipeline (spec §11.5, §11.8): one fetch per court order into court-orders/{cnr}/{sha256}.pdf, skipped once
stored, paused by the budgets, and out of the way of a fetch the API is already making."""

import asyncio
import hashlib
from collections.abc import AsyncIterator
from datetime import UTC, date, datetime
from decimal import Decimal

import httpx
import pytest
from conftest import Factory, FakeProvider, Org, _up, case_record, sql, unavailable

from advocate_shared.settings import get_settings
from advocate_workers import celery_app, db, orders, storage
from advocate_workers.diff import apply_case
from court_data.models import OrderRef

TODAY = date(2026, 10, 26)
ORDER = OrderRef("order-7.pdf", date(2026, 10, 20), "order")


async def remove_objects(paths: list[str]) -> None:
    s = get_settings()
    key = s.supabase_service_role_key
    async with httpx.AsyncClient(headers={"Authorization": f"Bearer {key}", "apikey": key}) as c:
        await c.request("DELETE", f"{s.supabase_server_url}/storage/v1/object/court-orders", json={"prefixes": paths})


@pytest.fixture
async def order(make: Factory) -> AsyncIterator[tuple[str, str, Org]]:
    """A court order of a case one organisation tracks: (court_order_id, cnr, org). Stored PDFs are removed after."""
    if not _up(55321):
        pytest.skip("local Supabase not running (just dev)")
    org = await make.org()
    cnr = make.cnr()
    await make.matter(org, cnr)
    async with db.engine().begin() as c:
        await apply_case(c, case_record(cnr, orders=(ORDER,)), datetime(2026, 10, 26, tzinfo=UTC))
    [row] = await sql("select id::text from public.court_orders where cnr = :c", c=cnr)
    yield row["id"], cnr, org
    stored = await sql("select storage_path from public.court_orders where cnr = :c", c=cnr)
    if paths := [s["storage_path"] for s in stored if s["storage_path"]]:
        await remove_objects(paths)


async def test_an_order_pdf_is_fetched_once_and_stored_by_content(order, provider: FakeProvider, r):
    order_id, cnr, _ = order
    pdf = b"%PDF-1.4 order seven"
    provider.pdfs[(cnr, ORDER.provider_ref)] = pdf
    assert await orders.fetch_order(r, order_id, TODAY) == "stored"
    sha = hashlib.sha256(pdf).hexdigest()
    path = f"{cnr}/{sha}.pdf"
    assert await sql("select storage_path, sha256 from public.court_orders where id = :id", id=order_id) == [
        {"storage_path": path, "sha256": sha}
    ]
    assert await storage.get("court-orders", path) == pdf
    assert await r.get(f"order-pdf:{order_id}") is None  # lock released

    assert await orders.fetch_order(r, order_id, TODAY) == "skipped"
    assert await asyncio.to_thread(orders.order_pipeline, order_id) == "skipped"  # the Celery task, in its own loop
    assert celery_app.ORDER_PIPELINE in celery_app.app.tasks
    assert provider.calls == [("get_order_pdf", (cnr, ORDER.provider_ref))]
    costs = await sql("select org_id, cnr, cost_inr from public.provider_calls where provider = :p", p=provider.name)
    assert costs == [{"org_id": None, "cnr": cnr, "cost_inr": Decimal("1.25")}]  # a platform row


async def test_the_pipeline_pauses_on_budgets_and_leaves_a_running_fetch_alone(
    order, provider: FakeProvider, r, monkeypatch
):
    order_id, _, org = order
    await r.set(f"order-pdf:{order_id}", "api", ex=60)  # the API is fetching it for someone who opened it
    try:
        assert await orders.fetch_order(r, order_id, TODAY) == "busy"
    finally:
        await r.delete(f"order-pdf:{order_id}")

    settings = get_settings()
    monkeypatch.setattr(settings, "courtdata_org_monthly_default_inr", Decimal("0.10"))
    await sql(
        "insert into public.provider_calls (provider, operation, org_id, cost_inr, status) "
        "values (:p, 'search', :o, 1, 'ok')",
        p=provider.name, o=org.id,
    )  # fmt: skip
    assert await orders.fetch_order(r, order_id, TODAY) == "paused"  # every org tracking it is over budget

    monkeypatch.setattr(settings, "courtdata_org_monthly_default_inr", None)
    monkeypatch.setattr(settings, "courtdata_global_daily_cap_inr", Decimal(0))  # reached, whatever others spend
    alert_day = date(2031, 4, 1)  # the once-a-day global alert key is shared: keep this test's apart
    try:
        assert await orders.fetch_order(r, order_id, alert_day) == "paused"
    finally:
        await r.delete(*(f"budget-alert:global:{level}:{alert_day}" for level in (80, 100)))
    assert provider.calls == []

    monkeypatch.setattr(settings, "courtdata_global_daily_cap_inr", None)
    provider.fail["get_order_pdf"] = unavailable()
    assert await orders.fetch_order(r, order_id, TODAY) == "failed"
    assert await sql("select storage_path from public.court_orders where id = :id", id=order_id) == [
        {"storage_path": None}
    ]
