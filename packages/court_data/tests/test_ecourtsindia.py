"""Contract tests for the eCourtsIndia provider against the synthetic stand-in (no live calls, spec §11.2).
Spike 11e adds recorded responses alongside."""

from datetime import date
from decimal import Decimal

import httpx
import pytest

from court_data.ecourtsindia import EcourtsIndiaProvider
from court_data.fake import ANCHOR, synthetic_transport
from court_data.models import Advocate, Capability, CaseNotFound, CaseSearchQuery, CauseListQuery, ProviderError

BASE = "https://webapi.ecourtsindia.com/api/partner"
TOMORROW = date(2026, 10, 27)


def provider(transport: httpx.AsyncBaseTransport | None = None, **kwargs) -> EcourtsIndiaProvider:
    return EcourtsIndiaProvider(
        base_url=BASE, api_key="eci_test", transport=transport or synthetic_transport(), **kwargs
    )


def replying(status: int, **kwargs) -> httpx.MockTransport:
    return httpx.MockTransport(lambda _: httpx.Response(status, **kwargs))


async def test_case_detail_maps_to_court_case_fields():
    c = await provider().get_case("TEST010000012024")
    assert (c.case_type, c.case_number, c.case_year) == ("WP", "1234", 2024)
    assert c.title == "Asha Verma v. State of Madhya Pradesh & Ors."
    assert (c.court_code, c.court_no, c.stage, c.status) == ("TESTMPHCIND", "12", "Admission", "pending")
    assert (c.next_hearing_date, c.last_hearing_date) == (TOMORROW, date(2026, 10, 13))
    assert Advocate("Neha Sharma", "petitioner") in c.advocates
    first = c.hearings[0]
    assert (first.hearing_date, first.next_date, first.purpose) == (date(2026, 9, 29), date(2026, 10, 13), "Notice")
    assert first.business and first.business.startswith("Notice")
    assert [(o.provider_ref, o.order_type) for o in c.orders] == [("order-1.pdf", "interim")]
    assert c.raw["courtCaseData"]["cnr"] == c.cnr


async def test_disposed_case_and_judgment():
    c = await provider().get_case("TEST050000052024")
    assert (c.status, c.next_hearing_date, c.decision_date) == ("disposed", None, date(2026, 8, 20))
    assert [o.order_type for o in c.orders] == ["judgment"]


async def test_unknown_cnr_is_not_found():
    with pytest.raises(CaseNotFound):
        await provider().get_case("TEST990000992024")


async def test_content_hash_ignores_raw_and_follows_fields():
    p = provider()
    a, b = await p.get_case("TEST010000012024"), await p.get_case("TEST010000012024")
    assert a.content_hash() == b.content_hash()
    moved = await provider(synthetic_transport(today=date(2026, 11, 2))).get_case("TEST010000012024")
    assert moved.next_hearing_date == date(2026, 11, 3)
    assert moved.content_hash() != a.content_hash()


async def test_search_by_advocate_pages_and_finds_partial_names():
    p = provider()
    page = await p.search_cases(CaseSearchQuery(advocate="Neha Sharma", page_size=3))
    assert (page.total, len(page.items), page.has_next) == (8, 3, True)
    everything = await p.search_cases(CaseSearchQuery(advocate="Neha Sharma"))
    hit = next(h for h in everything.items if h.cnr == "TEST070000072024")
    assert hit.advocates == (Advocate("N. Sharma", "petitioner"), Advocate("Central Government Counsel", "respondent"))
    assert (hit.case_number, hit.case_year, hit.court_code) == ("99", 2024, "TESTMPHCJBP")


async def test_search_filters_by_court_code():
    page = await provider().search_cases(CaseSearchQuery(advocate="Neha Sharma", court_codes=("TESTDCIND",)))
    assert {h.cnr for h in page.items} == {"TEST030000032024", "TEST050000052024"}


async def test_cause_list_batch_returns_only_the_given_day():
    cnrs = ["TEST010000012024", "TEST020000022024", "TEST030000032024", "TEST070000072024", "TEST080000082024"]
    hits = await provider().check_cause_list(cnrs, TOMORROW)
    assert {h.cnr for h in hits} == set(cnrs[:3])
    first = next(h for h in hits if h.cnr == cnrs[0])
    assert (first.court_no, first.item_no, first.court_code, first.list_date) == ("12", "23", "TESTMPHCIND", TOMORROW)
    with pytest.raises(ValueError):
        await provider().check_cause_list([], TOMORROW)


async def test_cause_list_search_by_advocate_and_date():
    hits = await provider().search_cause_list(CauseListQuery(on=TOMORROW, advocate="Neha Sharma"))
    assert {h.cnr for h in hits} == {"TEST010000012024", "TEST020000022024", "TEST030000032024"}


async def test_refresh_and_bulk_refresh():
    p = provider()
    one = await p.refresh_case("TEST010000012024")
    assert (one.cnrs, one.changed) == (("TEST010000012024",), None)
    bulk = await p.bulk_refresh(["TEST010000012024", "TEST990000992024"])
    assert bulk.cnrs == ("TEST010000012024",)
    assert (await p.bulk_refresh(["TEST020000022024"])).ready_in_s == 10
    with pytest.raises(ValueError):
        await p.bulk_refresh([f"TEST01{i:010d}" for i in range(51)])


async def test_order_pdf():
    pdf = await provider().get_order_pdf("TEST010000012024", "order-1.pdf")
    assert pdf.startswith(b"%PDF-1.4") and pdf.rstrip().endswith(b"%%EOF")
    with pytest.raises(CaseNotFound):
        await provider().get_order_pdf("TEST010000012024", "order-9.pdf")
    json_reply = replying(200, json={"data": {"filename": "order-1.pdf"}})
    with pytest.raises(ProviderError, match="did not return a PDF"):
        await provider(json_reply).get_order_pdf("TEST010000012024", "order-1.pdf")


@pytest.mark.parametrize(
    ("status", "code", "retryable"),
    [
        (402, "INSUFFICIENT_CREDITS", True),
        (429, "RATE_LIMIT_EXCEEDED", True),
        (503, "UPSTREAM", True),
        (401, "INVALID_TOKEN", False),
        (400, "INVALID_CNR", False),
    ],
)
async def test_errors_carry_code_and_retryability(status, code, retryable):
    body = {"error": {"code": code, "message": "x", "details": []}, "meta": {}}
    with pytest.raises(ProviderError) as e:
        await provider(replying(status, json=body)).get_case("TEST010000012024")
    assert (e.value.code, e.value.retryable, e.value.http_status) == (code, retryable, status)


async def test_network_failure_is_unavailable():
    def fail(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("down", request=request)

    with pytest.raises(ProviderError) as e:
        await provider(httpx.MockTransport(fail)).get_case("TEST010000012024")
    assert (e.value.code, e.value.retryable) == ("COURT_PROVIDER_UNAVAILABLE", True)


def test_costs_follow_base_rate_and_multiplier():
    payg, enterprise = provider(), provider(rate_multiplier=1)
    assert payg.cost_inr(Capability.SEARCH) == Decimal("0.60")
    assert payg.cost_inr(Capability.BULK_REFRESH, 10) == Decimal("1.50")
    assert enterprise.cost_inr(Capability.ORDER_PDF) == Decimal("1.25")
    assert enterprise.cost_inr(Capability.WEBHOOKS) == 0


def test_synthetic_anchor_is_a_monday():
    assert ANCHOR.weekday() == 0
