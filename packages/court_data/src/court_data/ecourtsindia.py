"""eCourtsIndia partner API, the primary provider (spec §11.3). Paths and payload shapes follow their public docs
(ecourtsindia.com/api/docs, read 24 Oct 2026); spike 11e confirms them against recorded responses. Their AI
endpoints (order-ai, legal-check) are not used."""

from datetime import date
from decimal import Decimal
from typing import Any, Literal

import httpx

from court_data.models import (
    Advocate,
    Capability,
    CaseHit,
    CaseNotFound,
    CaseRecord,
    CaseSearchQuery,
    CaseStatus,
    CauseListHit,
    CauseListQuery,
    HearingRecord,
    OrderRef,
    ProviderError,
    RefreshTicket,
    SearchPage,
)

# Base rate in INR per call, or per CNR for the batch operations (§11.3). Re-verify at integration time.
BASE_PRICES = {
    Capability.SEARCH: Decimal("0.20"),
    Capability.CASE_DETAIL: Decimal("0.50"),
    Capability.REFRESH: Decimal("0.05"),
    Capability.BULK_REFRESH: Decimal("0.05"),
    Capability.CAUSELIST_CNR_BATCH: Decimal("0.10"),
    Capability.CAUSELIST_SEARCH: Decimal("1.00"),
    Capability.ORDER_PDF: Decimal("1.25"),
}
STATUS: dict[str, CaseStatus] = {
    "PENDING": "pending",
    "DISPOSED": "disposed",
    "DISMISSED": "disposed",
    "TRANSFERRED": "transferred",
}
UNAVAILABLE = {402, 408, 429}  # out of credits or throttled: the provider is down for us, so fail over


class EcourtsIndiaProvider:
    name = "ecourtsindia"
    capabilities = frozenset(BASE_PRICES)

    def __init__(
        self,
        *,
        base_url: str,
        api_key: str,
        rate_multiplier: int = 3,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        self._http = httpx.AsyncClient(
            base_url=base_url, headers={"Authorization": f"Bearer {api_key}"}, transport=transport, timeout=20
        )
        self._multiplier = Decimal(rate_multiplier)

    async def aclose(self) -> None:
        await self._http.aclose()

    def cost_inr(self, op: Capability, n: int = 1) -> Decimal:
        return BASE_PRICES.get(op, Decimal(0)) * n * self._multiplier

    async def _call(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        try:
            r = await self._http.request(method, path, **kwargs)
        except httpx.TransportError as e:
            raise ProviderError("COURT_PROVIDER_UNAVAILABLE", str(e), retryable=True) from e
        if r.status_code == 404:
            raise CaseNotFound(path)
        if r.status_code >= 400:
            try:
                code = r.json()["error"]["code"]
            except ValueError, KeyError, TypeError:
                code = f"HTTP_{r.status_code}"
            retryable = r.status_code in UNAVAILABLE or r.status_code >= 500
            raise ProviderError(code, r.text[:200], retryable=retryable, http_status=r.status_code)
        return r

    async def _data(self, method: str, path: str, **kwargs: Any) -> Any:
        return (await self._call(method, path, **kwargs)).json()["data"]

    async def search_cases(self, q: CaseSearchQuery) -> SearchPage[CaseHit]:
        params = {
            "query": q.text,
            "advocates": q.advocate,
            "litigants": q.party,
            "judges": q.judge,
            "courtCodes": list(q.court_codes) or None,
            "filingDateFrom": q.filed_from and q.filed_from.isoformat(),
            "page": q.page,
            "pageSize": q.page_size,
        }
        d = await self._data("GET", "/search", params={k: v for k, v in params.items() if v is not None})
        return SearchPage(
            items=tuple(_hit(r) for r in d.get("results", [])),
            total=d.get("totalHits", 0),
            page=d.get("page", q.page),
            has_next=bool(d.get("hasNextPage")),
        )

    async def get_case(self, cnr: str) -> CaseRecord:
        d = await self._data("GET", f"/case/{cnr}")
        c = d["courtCaseData"]
        number, year = _split_number(c.get("registrationNumber") or c.get("filingNumber"))
        business = {e.get("date"): e.get("business") for e in c.get("businessOnDateEntries") or []}
        history = [h for h in c.get("historyOfCaseHearings") or [] if h.get("businessOnDate")]
        return CaseRecord(
            cnr=c["cnr"],
            provider=self.name,
            court_code=c.get("courtComplexCode") or c.get("cnrCourtCode"),
            case_type=c.get("caseType"),
            case_number=number,
            case_year=year,
            filing_no=c.get("filingNumber"),
            registration_no=c.get("registrationNumber"),
            title=_title(c),
            petitioners=tuple(c.get("petitioners") or ()),
            respondents=tuple(c.get("respondents") or ()),
            advocates=_advocates(c),
            judge=", ".join(c.get("judges") or ()) or (history[-1].get("judge") if history else None),
            court_no=_str(c.get("courtNo")),
            stage=c.get("purpose"),
            status=STATUS.get(c.get("caseStatus") or "", "unknown"),
            next_hearing_date=_date(c.get("nextHearingDate")),
            last_hearing_date=_date(c.get("lastHearingDate")),
            decision_date=_date(c.get("decisionDate")),
            acts=tuple(
                " ".join(str(p[k]) for k in ("act", "unit", "number") if p.get(k)) for p in c.get("provisions") or ()
            ),
            hearings=tuple(
                HearingRecord(
                    hearing_date=date.fromisoformat(h["businessOnDate"]),  # "Business on date" is the sitting itself
                    purpose=h.get("purposeOfListing"),
                    judge=h.get("judge"),
                    business=business.get(h["businessOnDate"]),
                    next_date=_date(h.get("hearingDate")),  # "Hearing date" is the date it was put off to
                )
                for h in history
            ),
            orders=tuple(
                OrderRef(o["orderUrl"], _date(o.get("orderDate")), _order_type(kind, o))
                for kind in ("judgmentOrders", "interimOrders")
                for o in c.get(kind) or ()
            ),
            raw=d,
        )

    async def refresh_case(self, cnr: str) -> RefreshTicket:
        await self._call("POST", f"/case/{cnr}/refresh")
        return RefreshTicket((cnr,), changed=None, ready_in_s=10)

    async def bulk_refresh(self, cnrs: list[str]) -> RefreshTicket:
        if len(cnrs) == 1:  # the bulk endpoint takes 2-50
            return await self.refresh_case(cnrs[0])
        if not 1 < len(cnrs) <= 50:
            raise ValueError("bulk_refresh takes 1-50 CNRs; batch them")
        d = await self._data("POST", "/case/bulk-refresh", json={"cnrs": cnrs})
        invalid = set(d.get("invalid") or ())
        return RefreshTicket(tuple(c for c in cnrs if c not in invalid), changed=None, ready_in_s=30)

    async def check_cause_list(self, cnrs: list[str], on: date) -> list[CauseListHit]:
        if not 0 < len(cnrs) <= 100:
            raise ValueError("check_cause_list takes 1-100 CNRs; batch them")
        rows = await self._data("POST", "/causelist/cnr/batch", json={"cnrs": cnrs})
        hits = [_listing(r["nextListing"]) for r in rows if r.get("hasCauselist") and r.get("nextListing")]
        return [h for h in hits if h.list_date == on]

    async def search_cause_list(self, q: CauseListQuery) -> list[CauseListHit]:
        params = {
            "date": q.on.isoformat(),
            "advocate": q.advocate,
            "litigant": q.litigant,
            "state": q.state,
            "courtComplexCode": q.court_complex_code,
            "limit": q.limit,
            "offset": q.offset,
        }
        d = await self._data("GET", "/causelist/search", params={k: v for k, v in params.items() if v is not None})
        return [_listing(r) for r in d.get("results", [])]

    async def get_order_pdf(self, cnr: str, order_ref: str) -> bytes:
        r = await self._call("GET", f"/case/{cnr}/order/{order_ref}")
        if not r.headers.get("content-type", "").startswith("application/pdf"):
            # The docs list JSON fields for this endpoint; spike 11e confirms how the file itself arrives.
            raise ProviderError("ORDER_PDF_UNAVAILABLE", "order endpoint did not return a PDF")
        return r.content


def _date(v: str | None) -> date | None:
    return date.fromisoformat(v[:10]) if v else None


def _str(v: Any) -> str | None:
    return None if v in (None, "") else str(v)


def _split_number(v: str | None) -> tuple[str | None, int | None]:
    """'24807/2016' or 'WP/1234/2024' → ('1234', 2024)."""
    parts = (v or "").split("/")
    if len(parts) >= 2 and parts[-1].isdigit():
        return parts[-2], int(parts[-1])
    return v or None, None


def _title(c: dict[str, Any]) -> str:
    def side(names: list[str] | None) -> str:
        names = names or ["—"]
        return names[0] + (" & Ors." if len(names) > 1 else "")

    return f"{side(c.get('petitioners'))} v. {side(c.get('respondents'))}"


def _advocates(c: dict[str, Any]) -> tuple[Advocate, ...]:
    return tuple(Advocate(n, "petitioner") for n in c.get("petitionerAdvocates") or ()) + tuple(
        Advocate(n, "respondent") for n in c.get("respondentAdvocates") or ()
    )


def _order_type(kind: str, o: dict[str, Any]) -> Literal["order", "judgment", "interim"]:
    if kind == "interimOrders":
        return "interim"
    return "judgment" if "JUDGMENT" in (o.get("orderType") or "").upper() else "order"


def _hit(r: dict[str, Any]) -> CaseHit:
    number, year = _split_number(r.get("registrationNumber"))
    return CaseHit(
        cnr=r["cnr"],
        court_code=r.get("courtCode"),
        case_type=r.get("caseType"),
        case_number=number,
        case_year=year,
        title=_title(r),
        status=STATUS.get(r.get("caseStatus") or "", "unknown"),
        next_hearing_date=_date(r.get("nextHearingDate")),
        petitioners=tuple(r.get("petitioners") or ()),
        respondents=tuple(r.get("respondents") or ()),
        advocates=_advocates(r),
    )


def _listing(r: dict[str, Any]) -> CauseListHit:
    return CauseListHit(
        cnr=r.get("cnr"),
        list_date=date.fromisoformat(r["date"][:10]),
        court_code=r.get("courtComplexCode"),
        court_name=r.get("courtName"),
        court_no=_str(r.get("courtNo")),
        item_no=_str(r.get("listingNo")),
        list_type=r.get("listType"),
        bench=r.get("bench"),
        judge=r.get("judge"),
        case_ref=r.get("caseNumber"),
    )
