"""Onboarding "find my cases" (FIND_CASES job, spec §11.4, §4.1 Found cases) and the Sunday auto_match (§11.5): one
advocate-name search, merged by CNR, scored and written to `found_cases` page by page, so a cancel or a failure keeps
what was found.

Confidence (§11.4 step 4): `high` when a name on the case is the advocate's name exactly (search_key, so "Sharma" =
"शर्मा", honorifics dropped) and the court is a practice court; otherwise `low`, as `outside_practice_courts` or
`partial_name`. Providers return no enrolment numbers, so the `enrolment` reason never fires. Only search calls run
here (step 7): case detail is fetched for the cases the user adds (FETCH_CASES). A Bar Council state may come as a
code ("MP") or a name ("Madhya Pradesh", the onboarding default); with no court the provider can search, the job
fails with NO_SEARCHABLE_COURTS rather than report nothing found."""

import json
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from datetime import date
from typing import Any
from uuid import UUID

import structlog
from celery import Task
from redis.asyncio import Redis

from advocate_shared import tasks
from advocate_shared.ist import today_ist
from advocate_shared.search_key import search_key
from advocate_workers import db, jobs
from advocate_workers.celery_app import AUTO_MATCH, app
from advocate_workers.courts import CourtData, Paused, Spend, court_codes, court_days, court_ids
from court_data.models import (
    Capability,
    CaseHit,
    CaseSearchQuery,
    CauseListHit,
    CauseListQuery,
    CourtDataProvider,
    ProviderError,
    SearchPage,
)

log = structlog.get_logger()

LEVELS = ("HC", "DC", "SC", "TRIBUNAL")  # progress groups, in the order the onboarding screen animates them
MAX_SEARCHES = 20  # case-search calls per advocate (§11.4 step 2)
MAX_CAUSE_LISTS = 7  # cause-list searches: one per court day
FEW = 10  # fewer unique CNRs than this, and the cause lists are searched too
# Compared on the word as written, never its phonetic key: "Dhar" and "Dr" share one.
HONORIFICS = frozenset("adv advocate shri sri smt mr mrs ms dr km श्री श्रीमती सुश्री डॉ अधिवक्ता एडवोकेट".split())
# Bar Council state names → courts.state.
# ponytail: only the states with seeded courts; add a state's names with its courts (P7).
STATE_CODES = {"madhya pradesh": "MP", "मध्य प्रदेश": "MP", "मध्यप्रदेश": "MP"}

COURTS = """
select id, level, state from public.courts
where case when cardinality(cast(:ids as uuid[])) > 0 then id = any(cast(:ids as uuid[]))
  else upper(state) = upper(cast(:state as text)) end
"""
WRITE = """
insert into public.found_cases (org_id, user_id, job_id, source, cnr, court_id, case_type, case_number, case_year,
  court_no, title, next_date, case_status, confidence, match_reason)
select cast(:org as uuid), cast(:user as uuid), cast(:job as uuid), :source, f.cnr, f.court_id, f.case_type,
  f.case_number, f.case_year, f.court_no, f.title, f.next_date, f.case_status, f.confidence, f.match_reason
from jsonb_to_recordset(cast(:rows as jsonb)) as f(cnr text, court_id uuid, case_type text, case_number text,
  case_year int, court_no text, title text, next_date date, case_status text, confidence text, match_reason text)
where not exists (select 1 from public.matters m where m.org_id = cast(:org as uuid) and m.cnr = f.cnr
  and m.deleted_at is null)
on conflict (org_id, cnr) do {}
returning cnr
"""
# Onboarding refreshes a row still waiting for a decision; auto_match never touches an existing row.
REFRESH = """update set job_id = excluded.job_id, court_id = excluded.court_id, case_type = excluded.case_type,
  case_number = excluded.case_number, case_year = excluded.case_year, court_no = excluded.court_no,
  title = excluded.title, next_date = excluded.next_date, case_status = excluded.case_status,
  confidence = excluded.confidence, match_reason = excluded.match_reason
where found_cases.decision = 'pending'"""
SUMMARY = """
select count(*) as found, count(*) filter (where case_status = 'pending') as pending,
  count(*) filter (where case_status = 'disposed') as disposed, count(*) filter (where confidence = 'low') as low
from public.found_cases where job_id = :job
"""
ADVOCATES = """
select m.org_id::text, m.user_id::text, p.full_name, p.bar_council_state, p.practice_court_ids
from public.memberships m join public.profiles p on p.id = m.user_id
where m.status = 'active' and m.role in ('owner', 'advocate') and trim(coalesce(p.full_name, '')) <> ''
order by m.org_id, m.created_at
"""


def plain_name(name: str) -> str:
    """The name without honorifics, in either script: "Adv. Neha Sharma" → "Neha Sharma"."""
    return " ".join(w for w in name.split() if w.strip(".,").lower() not in HONORIFICS)


def state_code(state: str | None) -> str | None:
    """courts.state for a Bar Council state given as a code ("MP") or a name ("Madhya Pradesh", "मध्य प्रदेश")."""
    name = " ".join((state or "").split())
    return STATE_CODES.get(name.lower(), name.upper()) or None


def _from_case(h: CaseHit) -> dict[str, Any]:
    return {
        "cnr": h.cnr, "court_code": h.court_code, "names": [a.name for a in h.advocates], "case_type": h.case_type,
        "case_number": h.case_number, "case_year": h.case_year, "title": h.title or None,
        "next_date": h.next_hearing_date, "case_status": h.status,
    }  # fmt: skip


def _from_listing(h: CauseListHit) -> dict[str, Any]:
    # A listing names no advocates, so it can't confirm an exact match (low at best); a listed case is pending.
    return {"cnr": h.cnr, "court_code": h.court_code, "names": [], "court_no": h.court_no, "next_date": h.list_date,
            "case_status": "pending"}  # fmt: skip


@dataclass
class Search:
    """One advocate's search for one organisation (§11.4 steps 2-5), costed to the organisation."""

    cd: CourtData
    org_id: str
    user_id: str
    name: str
    source: str  # found_cases.source
    job_id: str | None = None
    practice: set[UUID] = field(default_factory=set)
    state: str | None = None  # the practice courts' state, when they share one
    groups: dict[str, tuple[str, ...]] = field(default_factory=dict)  # level → the provider's court codes
    seen: set[str] = field(default_factory=set)  # CNRs merged so far, tracked ones included
    found: int = 0  # found_cases rows this search (job) wrote
    calls: int = 0
    ok: int = 0

    @classmethod
    async def start(
        cls,
        cd: CourtData,
        practice_ids: list[Any],
        state: str | None,
        *,
        org_id: str,
        user_id: str,
        name: str,
        source: str,
        job_id: str | None = None,
    ) -> Search:
        """Practice courts are `practice_ids`, or every court in the Bar Council's state. Courts the provider has no
        code for can't be searched, so they form no group. A redelivered job picks up the rows it already wrote."""
        s = cls(cd, org_id, user_id, name, source, job_id)
        async with db.engine().connect() as c:
            courts = await db.rows(c, COURTS, ids=[UUID(str(i)) for i in practice_ids], state=state_code(state))
            codes = await court_codes(c, cd.provider, [r["id"] for r in courts])
            if s.job_id:
                earlier = await db.rows(c, "select cnr from public.found_cases where job_id = :j", j=s.job_id)
                s.seen = {r["cnr"] for r in earlier}
        s.practice, s.found = {r["id"] for r in courts}, len(s.seen)
        if len(states := {r["state"] for r in courts}) == 1:
            s.state = states.pop()
        for level in LEVELS:
            if found := sorted(codes[r["id"]] for r in courts if r["level"] == level and r["id"] in codes):
                s.groups[level] = tuple(found)
        return s

    async def cases(self, level: str, groups_left: int) -> AsyncIterator[int]:
        """Case searches by advocate name in one group, page by page; yields the rows each page wrote. The groups
        still to search share what is left of MAX_SEARCHES, so one busy court can't starve the others."""
        page, more, budget = 1, True, (MAX_SEARCHES - self.calls) // groups_left
        while more and budget > 0:
            q = CaseSearchQuery(advocate=plain_name(self.name), court_codes=self.groups[level], page=page)
            result = await self._call(Capability.SEARCH, _search_cases(q))
            yield await self._write([_from_case(h) for h in result.items])
            page, more, budget = page + 1, result.has_next, budget - 1

    def cause_list_query(self, day: date) -> CauseListQuery:
        """A cause-list search by advocate in the practice courts (§11.4 step 2, §11.5 advocate_watch). The query
        takes one court or one state: the court when there is a single practice court, else their state (none when
        they span states, e.g. with the Supreme Court)."""
        codes = [c for group in self.groups.values() for c in group]
        court = codes[0] if len(codes) == 1 else None
        return CauseListQuery(on=day, advocate=plain_name(self.name), state=self.state, court_complex_code=court)

    async def cause_lists(self, days: list[date]) -> AsyncIterator[int]:
        """Cause-list searches by advocate for the given court days (§11.4 step 2); yields the rows each wrote."""
        for day in days[:MAX_CAUSE_LISTS]:
            hits = await self._call(Capability.CAUSELIST_SEARCH, _search_cause_list(self.cause_list_query(day)))
            yield await self._write([_from_listing(h) for h in hits])

    async def _call[T](self, op: Capability, fn: Callable[[CourtDataProvider], Awaitable[T]]) -> T:
        self.calls += 1
        result = await self.cd.call(Spend.ORG, op, fn, org_id=self.org_id)
        self.ok += 1
        return result

    async def _write(self, found: list[dict[str, Any]]) -> int:
        """Merge by CNR (the first sighting wins), score, and upsert; CNRs the organisation tracks are skipped."""
        fresh = []
        for f in found:
            if f["cnr"] and f["cnr"] not in self.seen:
                self.seen.add(f["cnr"])
                fresh.append(f)
        if not fresh:
            return 0
        key = search_key(plain_name(self.name))
        async with db.engine().begin() as c:
            ids = await court_ids(c, self.cd.provider, (f["court_code"] for f in fresh))
            rows = [self._score(f, ids.get(f["court_code"]), key) for f in fresh]
            written = await db.rows(
                c, WRITE.format(REFRESH if self.source == "onboarding" else "nothing"),
                org=self.org_id, user=self.user_id, job=self.job_id, source=self.source,
                rows=json.dumps(rows, default=str),
            )  # fmt: skip
        self.found += len(written)
        return len(written)

    def _score(self, f: dict[str, Any], court_id: UUID | None, key: str) -> dict[str, Any]:
        exact = bool(key) and any(search_key(plain_name(n)) == key for n in f["names"])
        reason = (
            "outside_practice_courts" if court_id not in self.practice
            else "exact_name_practice_court" if exact
            else "partial_name"
        )  # fmt: skip
        confidence = "high" if reason == "exact_name_practice_court" else "low"
        return {**f, "court_id": court_id, "confidence": confidence, "match_reason": reason}

    async def summary(self) -> dict[str, int]:
        async with db.engine().connect() as c:
            return (await db.rows(c, SUMMARY, job=self.job_id))[0]


def _search_cases(q: CaseSearchQuery) -> Callable[[CourtDataProvider], Awaitable[SearchPage[CaseHit]]]:
    return lambda p: p.search_cases(q)


def _search_cause_list(q: CauseListQuery) -> Callable[[CourtDataProvider], Awaitable[list[CauseListHit]]]:
    return lambda p: p.search_cause_list(q)


async def run_find_cases(job: jobs.Job, r: Redis, today: date) -> dict[str, Any] | None:
    """The FIND_CASES body. jobs.progress = {"groups": [{"key": "HC", "state": "pending|running|done|failed",
    "found": n}], "found": total}; a redelivered job skips its done groups. Stops as soon as the job is cancelled.
    Every search failing fails the job with COURT_PROVIDER_UNAVAILABLE (rows found so far are kept)."""
    i = job.input
    async with CourtData(r, today) as cd:
        s = await Search.start(
            cd, i.get("practice_court_ids") or [], i.get("bar_council_state"),
            org_id=str(job.org_id), user_id=job.user_id, name=i["advocate_name"], source="onboarding", job_id=job.id,
        )  # fmt: skip
        if not s.groups:
            raise jobs.JobFailed("NO_SEARCHABLE_COURTS")
        done = {g["key"]: g for g in job.progress.get("groups", []) if g["state"] == "done"}
        groups = [done.get(k) or {"key": k, "state": "pending", "found": 0} for k in s.groups]
        progress = {"groups": groups, "found": s.found}

        async def report() -> bool:
            progress["found"] = s.found
            return await jobs.set_progress(job.id, progress)

        for n, g in enumerate(groups):
            if g["state"] == "done":
                continue
            g["state"] = "running"
            if not await report():
                return None
            try:
                async for written in s.cases(g["key"], sum(x["state"] != "done" for x in groups[n:])):
                    g["found"] += written
                    if not await report():
                        return None
                g["state"] = "done"
            except ProviderError as e:
                log.warning("find_cases_search_failed", job_id=job.id, group=g["key"], code=e.code)
                g["state"] = "failed"
            if not await report():
                return None

        # ponytail: a job redelivered after its groups finished searches the cause lists again (at most 7 calls);
        # keep a fallback state in progress if redeliveries ever get common.
        if len(s.seen) < FEW and any(Capability.CAUSELIST_SEARCH in p.capabilities for p in cd.providers):
            async with db.engine().connect() as c:
                days = await court_days(c, sorted(s.practice), today, MAX_CAUSE_LISTS)
            try:
                async for _ in s.cause_lists(days):
                    if not await report():
                        return None
            except ProviderError as e:
                log.warning("find_cases_cause_list_failed", job_id=job.id, code=e.code)

        result = await s.summary()
        if s.calls and not s.ok:
            raise jobs.JobFailed("COURT_PROVIDER_UNAVAILABLE", result)
        return result


async def advocates() -> list[dict[str, Any]]:
    """Active owners and advocates with a name, across organisations: whose cases auto_match looks for."""
    async with db.engine().connect() as c:
        return await db.rows(c, ADVOCATES)


async def run_auto_match(r: Redis, today: date) -> dict[str, int]:
    """Sunday 02:00 (§11.5): every advocate's case search again; new CNRs land in "Found for you". Existing rows
    (pending, added, skipped, or a `not_mine` exclusion) are never changed and tracked CNRs are skipped. An org over
    its monthly budget is skipped; the global daily cap stops the run."""
    async with jobs.scheduled(r, f"sched:auto_match:{today}") as first:
        if not first:
            return {"advocates": 0, "found": 0}
        people, found, paused = await advocates(), 0, set[str]()
        async with CourtData(r, today) as cd:
            for a in people:
                if a["org_id"] in paused:
                    continue
                s = await Search.start(
                    cd, a["practice_court_ids"], a["bar_council_state"],
                    org_id=a["org_id"], user_id=a["user_id"], name=a["full_name"], source="auto_match",
                )  # fmt: skip
                try:
                    for n, level in enumerate(s.groups):
                        async for _ in s.cases(level, len(s.groups) - n):
                            pass
                except Paused as e:
                    if e.code == "COURT_DATA_PAUSED":
                        break
                    paused.add(a["org_id"])
                except ProviderError as e:
                    log.warning("auto_match_search_failed", org_id=a["org_id"], code=e.code)
                finally:
                    found += s.found
        return {"advocates": len(people), "found": found}


@app.task(name=tasks.FIND_CASES, bind=True, max_retries=5)
def find_cases(self: Task, job_id: str) -> None:
    jobs.run_job(self, job_id, lambda job, r: run_find_cases(job, r, today_ist()))


@app.task(name=AUTO_MATCH)
def auto_match() -> dict[str, int]:
    return jobs.run_task(lambda r: run_auto_match(r, today_ist()))
