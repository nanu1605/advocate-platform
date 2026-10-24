"""Normalised court-data models and the provider interface (spec §11.2). Field names mirror `court_cases`,
`court_hearings`, `court_orders` and `cause_list_entries`, so workers copy them straight into those tables."""

import hashlib
import json
from dataclasses import asdict, dataclass, field
from datetime import date
from decimal import Decimal
from enum import StrEnum
from typing import Any, Literal, Protocol

type CaseStatus = Literal["pending", "disposed", "transferred", "unknown"]


class Capability(StrEnum):
    SEARCH = "search"
    CASE_DETAIL = "case_detail"
    REFRESH = "refresh"
    BULK_REFRESH = "bulk_refresh"
    CHANGE_SIGNAL = "change_signal"
    CAUSELIST_CNR_BATCH = "causelist_cnr_batch"
    CAUSELIST_SEARCH = "causelist_search"
    ORDER_PDF = "order_pdf"
    SECTION_EQUIVALENTS = "section_equivalents"
    WEBHOOKS = "webhooks"


class ProviderError(Exception):
    """`code` is an API error code (§10.1). Retryable errors mean the provider is unavailable: they count towards
    the circuit breaker."""

    def __init__(self, code: str, message: str = "", *, retryable: bool = False, http_status: int | None = None):
        super().__init__(message or code)
        self.code, self.retryable, self.http_status = code, retryable, http_status


class CaseNotFound(ProviderError):
    def __init__(self, cnr: str):
        super().__init__("CASE_NOT_FOUND", cnr, http_status=404)


@dataclass(frozen=True, slots=True)
class Advocate:
    name: str
    side: Literal["petitioner", "respondent"]


@dataclass(frozen=True, slots=True)
class HearingRecord:
    hearing_date: date
    purpose: str | None = None
    judge: str | None = None
    business: str | None = None
    next_date: date | None = None


@dataclass(frozen=True, slots=True)
class OrderRef:
    provider_ref: str
    order_date: date | None
    order_type: Literal["order", "judgment", "interim"]


@dataclass(frozen=True, slots=True)
class CaseHit:
    cnr: str
    court_code: str | None
    case_type: str | None
    case_number: str | None
    case_year: int | None
    title: str
    status: CaseStatus
    next_hearing_date: date | None
    petitioners: tuple[str, ...] = ()
    respondents: tuple[str, ...] = ()
    advocates: tuple[Advocate, ...] = ()


@dataclass(frozen=True, slots=True)
class CaseRecord:
    cnr: str
    provider: str
    court_code: str | None
    case_type: str | None
    case_number: str | None
    case_year: int | None
    filing_no: str | None
    registration_no: str | None
    title: str
    petitioners: tuple[str, ...]
    respondents: tuple[str, ...]
    advocates: tuple[Advocate, ...]
    judge: str | None
    court_no: str | None
    stage: str | None
    status: CaseStatus
    next_hearing_date: date | None
    last_hearing_date: date | None
    decision_date: date | None
    acts: tuple[str, ...]
    hearings: tuple[HearingRecord, ...]
    orders: tuple[OrderRef, ...]
    raw: dict[str, Any] = field(default_factory=dict, compare=False, repr=False)  # debugging only, never shown

    def content_hash(self) -> str:
        """Hash of the normalised fields (§11.6): only a changed hash triggers diff, events and fan-out."""
        fields = {k: v for k, v in asdict(self).items() if k != "raw"}
        return hashlib.sha256(json.dumps(fields, sort_keys=True, default=str).encode()).hexdigest()


@dataclass(frozen=True, slots=True)
class SearchPage[T]:
    items: tuple[T, ...]
    total: int
    page: int
    has_next: bool


@dataclass(frozen=True, slots=True)
class CaseSearchQuery:
    text: str | None = None
    advocate: str | None = None
    party: str | None = None
    judge: str | None = None
    court_codes: tuple[str, ...] = ()
    filed_from: date | None = None
    page: int = 1
    page_size: int = 50


@dataclass(frozen=True, slots=True)
class CauseListHit:
    cnr: str | None
    list_date: date
    court_code: str | None
    court_name: str | None
    court_no: str | None
    item_no: str | None
    list_type: str | None
    bench: str | None
    judge: str | None
    case_ref: str | None


@dataclass(frozen=True, slots=True)
class CauseListQuery:
    on: date
    advocate: str | None = None
    litigant: str | None = None
    state: str | None = None
    court_complex_code: str | None = None
    limit: int = 100
    offset: int = 0


@dataclass(frozen=True, slots=True)
class RefreshTicket:
    cnrs: tuple[str, ...]
    changed: bool | None  # None: the provider gives no change signal, so fetch detail and compare hashes
    ready_in_s: int


class CourtDataProvider(Protocol):
    """One licensed source (hard rule 1). Section equivalents (IPC↔BNS) join this interface with the P3 law
    converter; manual tracking is a matter state (`matters.tracking = 'manual'`), so it needs no provider."""

    name: str
    capabilities: frozenset[Capability]

    async def search_cases(self, q: CaseSearchQuery) -> SearchPage[CaseHit]: ...
    async def get_case(self, cnr: str) -> CaseRecord: ...
    async def refresh_case(self, cnr: str) -> RefreshTicket: ...
    async def bulk_refresh(self, cnrs: list[str]) -> RefreshTicket: ...
    async def check_cause_list(self, cnrs: list[str], on: date) -> list[CauseListHit]: ...
    async def search_cause_list(self, q: CauseListQuery) -> list[CauseListHit]: ...
    async def get_order_pdf(self, cnr: str, order_ref: str) -> bytes: ...
    def cost_inr(self, op: Capability, n: int = 1) -> Decimal: ...
