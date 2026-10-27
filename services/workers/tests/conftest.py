"""Worker test fixtures, against the local stack (Postgres 55322, Redis 6379, Storage 55321).

Tests run alongside other test runs, and court_* tables are global by CNR, so everything here is isolated: random
CNRs, fresh orgs and users, an in-memory provider with its own name (its provider_calls are deleted by that name),
and cleanup of everything created. Fixtures that need the stack skip when it is down; pure tests need none."""

import json
import random
import socket
import uuid
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from dataclasses import replace as _replace
from datetime import date
from decimal import Decimal
from typing import Any

import pytest
from redis.asyncio import Redis
from sqlalchemy import text

from advocate_workers import courts, db, jobs
from court_data.ecourtsindia import BASE_PRICES
from court_data.models import (
    Capability,
    CaseHit,
    CaseNotFound,
    CaseRecord,
    CaseSearchQuery,
    CauseListHit,
    CauseListQuery,
    ProviderError,
    RefreshTicket,
    SearchPage,
)

COURT_SC = "c0000000-0000-0000-0000-000000000001"
COURT_MPHC_JBP = "c0000000-0000-0000-0000-000000000002"
COURT_MPHC_IND = "c0000000-0000-0000-0000-000000000003"
COURT_DC_IND = "c0000000-0000-0000-0000-000000000005"


def _up(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


STACK_UP = _up(55322) and _up(6379)


def requires_stack() -> None:
    if not STACK_UP:
        pytest.skip("local stack not running (just dev)")


def random_cnr() -> str:
    """TEST + 12 random digits: never a real CNR, and never another test's."""
    return "TEST" + "".join(random.choices("0123456789", k=12))  # noqa: S311


def case_record(cnr: str, **fields: Any) -> CaseRecord:
    """A pending High Court (synthetic code TESTMPHCIND) writ petition with no hearings or orders; override any
    field. Change one later with dataclasses.replace."""
    base = CaseRecord(
        cnr=cnr,
        provider="fake",
        court_code="TESTMPHCIND",
        case_type="WP",
        case_number=str(random.randint(1, 99999)),  # noqa: S311
        case_year=2024,
        filing_no=None,
        registration_no=None,
        title="Ramesh Kumar v. State of MP",
        petitioners=("Ramesh Kumar",),
        respondents=("State of MP",),
        advocates=(),
        judge=None,
        court_no="12",
        stage="Admission",
        status="pending",
        next_hearing_date=None,
        last_hearing_date=None,
        decision_date=None,
        acts=(),
        hearings=(),
        orders=(),
    )
    return _replace(base, **fields)


class FakeProvider:
    """An in-memory CourtDataProvider. Set `cases`, `hits` (search_cases), `listings` (check_cause_list, by CNR),
    `cause_list` (search_cause_list) and `pdfs`; read `calls` as (method, argument). `fail[method]` makes that method
    raise: an exception raises on every call, a list is used up one call at a time (None = succeed). Costs are the
    eCourtsIndia base rates, so a test can predict provider_calls.cost_inr."""

    capabilities = frozenset(BASE_PRICES)

    def __init__(self) -> None:
        self.name = f"fake-{uuid.uuid4().hex[:10]}"  # provider_calls rows are cleaned up by this name
        self.cases: dict[str, CaseRecord] = {}
        self.hits: list[CaseHit] = []
        self.listings: dict[str, CauseListHit] = {}
        self.cause_list: list[CauseListHit] = []
        self.pdfs: dict[tuple[str, str], bytes] = {}
        self.calls: list[tuple[str, Any]] = []
        self.fail: dict[str, Exception | list[Exception | None]] = {}
        self.changed: bool | None = None
        self.ready_in_s = 0

    def _call(self, method: str, arg: Any) -> None:
        self.calls.append((method, arg))
        failure = self.fail.get(method)
        if isinstance(failure, list):
            failure = failure.pop(0) if failure else None
        if failure is not None:
            raise failure

    def add(self, record: CaseRecord) -> CaseRecord:
        self.cases[record.cnr] = record
        return record

    async def search_cases(self, q: CaseSearchQuery) -> SearchPage[CaseHit]:
        self._call("search_cases", q)
        last = (q.advocate or "").lower().split()[-1:]
        found = [
            h
            for h in self.hits
            if (not last or any(last[0] in a.name.lower().split() for a in h.advocates))
            and (not q.court_codes or h.court_code in q.court_codes)
        ]
        page = found[(q.page - 1) * q.page_size : q.page * q.page_size]
        return SearchPage(tuple(page), len(found), q.page, q.page * q.page_size < len(found))

    async def get_case(self, cnr: str) -> CaseRecord:
        self._call("get_case", cnr)
        if cnr not in self.cases:
            raise CaseNotFound(cnr)
        return self.cases[cnr]

    async def refresh_case(self, cnr: str) -> RefreshTicket:
        self._call("refresh_case", cnr)
        if cnr not in self.cases:
            raise CaseNotFound(cnr)
        return RefreshTicket((cnr,), self.changed, self.ready_in_s)

    async def bulk_refresh(self, cnrs: list[str]) -> RefreshTicket:
        self._call("bulk_refresh", list(cnrs))
        if not 0 < len(cnrs) <= 50:
            raise ValueError("bulk_refresh takes 1-50 CNRs; batch them")
        return RefreshTicket(tuple(c for c in cnrs if c in self.cases), self.changed, self.ready_in_s)

    async def check_cause_list(self, cnrs: list[str], on: date) -> list[CauseListHit]:
        self._call("check_cause_list", list(cnrs))
        if not 0 < len(cnrs) <= 100:
            raise ValueError("check_cause_list takes 1-100 CNRs; batch them")
        return [h for c in cnrs if (h := self.listings.get(c)) and h.list_date == on]

    async def search_cause_list(self, q: CauseListQuery) -> list[CauseListHit]:
        self._call("search_cause_list", q)
        return [h for h in self.cause_list if h.list_date == q.on]

    async def get_order_pdf(self, cnr: str, order_ref: str) -> bytes:
        self._call("get_order_pdf", (cnr, order_ref))
        return self.pdfs.get((cnr, order_ref), b"%PDF-1.4 fake order " + f"{cnr} {order_ref}".encode())

    def cost_inr(self, op: Capability, n: int = 1) -> Decimal:
        return BASE_PRICES.get(op, Decimal(0)) * n


def unavailable() -> ProviderError:
    """A retryable provider failure (the provider is down for us)."""
    return ProviderError("COURT_PROVIDER_UNAVAILABLE", "down", retryable=True, http_status=503)


async def sql(statement: str, **params: Any) -> list[dict[str, Any]]:
    """One statement in its own transaction, as the workers connect (bypasses RLS); rows as dicts."""
    async with db.engine().begin() as c:
        result = await c.execute(text(statement), params)
        return [dict(r) for r in result.mappings()] if result.returns_rows else []


@dataclass
class Org:
    id: str
    owner_id: str
    users: dict[str, str] = field(default_factory=dict)  # name -> user id, owner included


@dataclass
class Factory:
    """Creates test rows and removes them (and their court rows and cost records) afterwards."""

    provider: FakeProvider
    orgs: list[str] = field(default_factory=list)
    users: list[str] = field(default_factory=list)
    cnrs: list[str] = field(default_factory=list)

    def cnr(self) -> str:
        """A random CNR whose court rows, cause-list rows and cost records are deleted after the test."""
        cnr = random_cnr()
        self.cnrs.append(cnr)
        return cnr

    async def user(self, name: str = "Neha Sharma", lang: str = "en") -> str:
        uid = str(uuid.uuid4())
        await sql("insert into auth.users (id, aud, role) values (:u, 'authenticated', 'authenticated')", u=uid)
        await sql(
            "update public.profiles set full_name = :n, preferred_language = :l where id = :u", n=name, l=lang, u=uid
        )
        self.users.append(uid)
        return uid

    async def org(
        self, owner: str = "Neha Sharma", *, lang: str = "en", members: dict[str, str | tuple[str, str]] | None = None
    ) -> Org:
        """An organisation owned by a new user `owner`. `members` maps a name to a role, or (role, language); every
        membership is active."""
        owner_id = await self.user(owner, lang)
        org_id = str(uuid.uuid4())
        await sql(
            "insert into public.organizations (id, name, kind, owner_id) values (:id, :n, :k, :o)",
            id=org_id, n=f"{owner} chamber", k="chamber" if members else "solo", o=owner_id,
        )  # fmt: skip
        self.orgs.append(org_id)
        org = Org(org_id, owner_id, {owner: owner_id})
        for name, spec in (members or {}).items():
            role, member_lang = (spec, "en") if isinstance(spec, str) else spec
            uid = await self.user(name, member_lang)
            await sql(
                "insert into public.memberships (org_id, user_id, role, display_name) values (:o, :u, :r, :n)",
                o=org_id, u=uid, r=role, n=name,
            )  # fmt: skip
            org.users[name] = uid
        return org

    async def matter(
        self, org: Org, cnr: str | None = None, *, tracking: str = "auto", deleted: bool = False, **cols: Any
    ) -> str:
        """A matter in `org` (source 'cnr', MPHC Indore unless court_id is given); extra columns as keywords."""
        values = {"court_id": COURT_MPHC_IND, **cols}
        names = ", ".join(values)
        marks = ", ".join(f":{k}" for k in values)
        [row] = await sql(
            f"insert into public.matters (org_id, cnr, source, tracking, deleted_at, {names}) "
            f"values (:org, :cnr, 'cnr', :tracking, case when :deleted then now() end, {marks}) returning id::text",
            org=org.id, cnr=cnr, tracking=tracking, deleted=deleted, **values,
        )  # fmt: skip
        return row["id"]

    async def job(
        self,
        org: Org | None,
        kind: str,
        job_input: dict[str, Any],
        *,
        user: str | None = None,
        status: str = "queued",
        age_min: int = 0,
    ) -> str:
        """A jobs row as the API creates it (user defaults to the org owner), last touched `age_min` minutes ago."""
        user_id = user or (org.owner_id if org else await self.user())
        [row] = await sql(
            "insert into public.jobs (org_id, user_id, kind, input, status, updated_at) "
            "values (:o, :u, :k, cast(:i as jsonb), :s, now() - make_interval(mins => :age)) returning id::text",
            o=org.id if org else None, u=user_id, k=kind, i=json.dumps(job_input, default=str), s=status, age=age_min,
        )  # fmt: skip
        return row["id"]

    async def cleanup(self) -> None:
        mine = "provider = :p or org_id = any(cast(:orgs as uuid[])) or cnr = any(:cnrs)"
        p = {"p": self.provider.name, "orgs": self.orgs, "cnrs": self.cnrs}
        await sql(
            "delete from public.usage_ledger where ref_type = 'provider_calls' "
            f"and ref_id in (select id from public.provider_calls where {mine})",
            **p,
        )
        await sql(f"delete from public.provider_calls where {mine}", **p)
        await sql("delete from public.organizations where id = any(cast(:o as uuid[]))", o=self.orgs)
        await sql("delete from auth.users where id = any(cast(:u as uuid[]))", u=self.users)
        for table in ("cause_list_entries", "court_hearings", "court_orders", "court_cases"):
            await sql(f"delete from public.{table} where cnr = any(:c)", c=self.cnrs)


@pytest.fixture
def provider(monkeypatch: pytest.MonkeyPatch) -> FakeProvider:
    """The only provider CourtData sees in this test (courts.make_providers is patched)."""
    fake = FakeProvider()
    monkeypatch.setattr(courts, "make_providers", lambda today: [fake])
    return fake


@pytest.fixture
async def make(provider: FakeProvider) -> AsyncIterator[Factory]:
    requires_stack()
    factory = Factory(provider)
    yield factory
    await factory.cleanup()


@pytest.fixture
async def r() -> AsyncIterator[Redis]:
    requires_stack()
    client = db.redis()
    yield client
    await client.aclose()


@pytest.fixture
def sent(monkeypatch: pytest.MonkeyPatch) -> list[tuple[Any, ...]]:
    """Celery tasks the code would have sent, as (task name, args), or (task name, args, keywords) when it passed
    any (countdown included), instead of sending them."""
    calls: list[tuple[Any, ...]] = []
    monkeypatch.setattr(jobs, "send", lambda name, *args, **kw: calls.append((name, args, kw) if kw else (name, args)))
    return calls
