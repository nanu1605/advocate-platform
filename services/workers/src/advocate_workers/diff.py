"""Change detection (spec §11.6): store a fetched CaseRecord in the shared court tables and say what changed.

Only a changed content hash rewrites the court rows and produces events; an unchanged fetch just moves fetched_at.
The first fetch of a CNR is the baseline and produces no events, so imports never send a burst of notifications
or fetch old order PDFs. A sitting is one per case and date: a corrected purpose updates it in place, and a date the
provider no longer lists (a corrected date) is removed, with the diary hearings copied from it unless a member wrote
on them (their notes stay, as a hearing of their own)."""

import json
from dataclasses import asdict, dataclass
from datetime import datetime
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_shared.search_key import search_key
from advocate_workers import db
from advocate_workers.courts import court_ids
from court_data.models import CaseRecord


@dataclass(frozen=True, slots=True)
class Event:
    """Named like the notification kinds (§13.1): next_date_set (value: ISO date), new_order (value: provider_ref),
    status_changed (value: disposed|transferred), listed_unexpectedly (value: ISO list date)."""

    cnr: str
    kind: str
    value: str
    court_order_id: UUID | None = None  # new_order: the court_orders row the order pipeline fetches

    @property
    def key(self) -> str:
        """(cnr, event, value): stored per user in notifications.data.event_key, so retries never notify twice."""
        return f"{self.cnr}:{self.kind}:{self.value}"


# The CNR's tracking matters, locked before any diary row is touched (here, then fan_out): a concurrent
# public.delete_matter (the matter, then its hearings) waits for this transaction and soft-deletes what it wrote,
# instead of missing it or deadlocking. Ordered by id, so two transactions on one CNR queue up.
LOCK_MATTERS = """
select id from public.matters where cnr = :cnr and tracking = 'auto' and deleted_at is null order by id
for no key update
"""
UPSERT_CASE = """
insert into public.court_cases (cnr, court_id, case_type, case_number, case_year, filing_no, registration_no, title,
  petitioners, respondents, advocates, judge, court_no, stage, status, next_hearing_date, last_hearing_date,
  decision_date, acts, provider, fetched_at, content_hash, raw, search_key)
values (:cnr, :court_id, :case_type, :case_number, :case_year, :filing_no, :registration_no, :title,
  cast(:petitioners as jsonb), cast(:respondents as jsonb), cast(:advocates as jsonb), :judge, :court_no, :stage,
  :status, :next_hearing_date, :last_hearing_date, :decision_date, cast(:acts as jsonb), :provider, :now, :hash,
  cast(:raw as jsonb), :search_key)
on conflict (cnr) do update set court_id = excluded.court_id, case_type = excluded.case_type,
  case_number = excluded.case_number, case_year = excluded.case_year, filing_no = excluded.filing_no,
  registration_no = excluded.registration_no, title = excluded.title, petitioners = excluded.petitioners,
  respondents = excluded.respondents, advocates = excluded.advocates, judge = excluded.judge,
  court_no = excluded.court_no, stage = excluded.stage, status = excluded.status,
  next_hearing_date = excluded.next_hearing_date, last_hearing_date = excluded.last_hearing_date,
  decision_date = excluded.decision_date, acts = excluded.acts, provider = excluded.provider,
  fetched_at = excluded.fetched_at, content_hash = excluded.content_hash, raw = excluded.raw,
  search_key = excluded.search_key
"""
UPSERT_HEARINGS = """
insert into public.court_hearings (cnr, hearing_date, purpose, judge, business, next_date, source)
select :cnr, u.d, u.p, u.j, u.b, u.n, :provider
from unnest(cast(:d as date[]), cast(:p as text[]), cast(:j as text[]), cast(:b as text[]), cast(:n as date[]))
  as u(d, p, j, b, n)
on conflict (cnr, hearing_date) do update set purpose = excluded.purpose, judge = excluded.judge,
  business = excluded.business, next_date = excluded.next_date, source = excluded.source
"""
# A diary hearing a member wrote on stays (PRUNE_HEARINGS detaches it): user columns are never lost (§11.6).
DROP_HEARINGS = """
update public.hearings set deleted_at = now()
where deleted_at is null and court_hearing_id in (
  select id from public.court_hearings where cnr = :cnr and hearing_date <> all(cast(:d as date[])))
  and user_next_date is null and user_purpose is null and user_outcome is null and user_note is null and not confirmed
"""
PRUNE_HEARINGS = "delete from public.court_hearings where cnr = :cnr and hearing_date <> all(cast(:d as date[]))"
UPSERT_ORDERS = """
insert into public.court_orders (cnr, provider_ref, order_date, order_type)
select :cnr, u.r, u.d, u.t from unnest(cast(:r as text[]), cast(:d as date[]), cast(:t as text[])) as u(r, d, t)
on conflict (cnr, provider_ref) do update set order_date = excluded.order_date, order_type = excluded.order_type
returning id, provider_ref
"""


async def apply_case(conn: AsyncConnection, record: CaseRecord, now: datetime) -> list[Event]:
    """Store `record` and return its events (none for the baseline or an unchanged hash). Call fan_out next, in the
    same transaction, even with no events: it copies fetched_at and any court changes to the matters."""
    cnr = record.cnr
    await conn.execute(text("select pg_advisory_xact_lock(hashtextextended('court_case:' || :c, 0))"), {"c": cnr})
    await conn.execute(text(LOCK_MATTERS), {"cnr": cnr})
    old = await db.rows(
        conn, "select content_hash, next_hearing_date, status from public.court_cases where cnr = :c", c=cnr
    )
    digest = record.content_hash()
    if old and old[0]["content_hash"] == digest:
        await conn.execute(
            text("update public.court_cases set fetched_at = :now where cnr = :c"), {"now": now, "c": cnr}
        )
        return []

    court_id = (await court_ids(conn, record.provider, [record.court_code])).get(record.court_code or "")
    fields = asdict(record)
    await conn.execute(
        text(UPSERT_CASE),
        {
            **{k: fields[k] for k in ("cnr", "case_type", "case_number", "case_year", "filing_no", "registration_no")},
            **{k: fields[k] for k in ("title", "judge", "court_no", "stage", "status", "provider")},
            **{k: fields[k] for k in ("next_hearing_date", "last_hearing_date", "decision_date")},
            **{k: json.dumps(fields[k]) for k in ("petitioners", "respondents", "advocates", "acts")},
            "court_id": court_id,
            "now": now,
            "hash": digest,
            "raw": json.dumps(record.raw, default=str),
            "search_key": search_key(" ".join([record.title, *record.petitioners, *record.respondents])),
        },
    )
    hearings = list({h.hearing_date: h for h in record.hearings}.values())  # one row per conflict key
    # An empty history is likelier a partial answer than every sitting withdrawn: keep what is stored then.
    if hearings:
        dates = [h.hearing_date for h in hearings]
        await conn.execute(
            text(UPSERT_HEARINGS),
            {
                "cnr": cnr,
                "provider": record.provider,
                "d": dates,
                "p": [h.purpose for h in hearings],
                "j": [h.judge for h in hearings],
                "b": [h.business for h in hearings],
                "n": [h.next_date for h in hearings],
            },
        )
        for statement in (DROP_HEARINGS, PRUNE_HEARINGS):
            await conn.execute(text(statement), {"cnr": cnr, "d": dates})
    seen = {
        r["provider_ref"]
        for r in await db.rows(conn, "select provider_ref from public.court_orders where cnr = :c", c=cnr)
    }
    orders = list({o.provider_ref: o for o in record.orders}.values())
    stored = []
    if orders:
        stored = await db.rows(
            conn,
            UPSERT_ORDERS,
            cnr=cnr,
            r=[o.provider_ref for o in orders],
            d=[o.order_date for o in orders],
            t=[o.order_type for o in orders],
        )
    if not old:
        return []  # baseline

    events = [Event(cnr, "new_order", o["provider_ref"], o["id"]) for o in stored if o["provider_ref"] not in seen]
    if record.next_hearing_date and record.next_hearing_date != old[0]["next_hearing_date"]:
        events.append(Event(cnr, "next_date_set", record.next_hearing_date.isoformat()))
    if record.status in ("disposed", "transferred") and record.status != old[0]["status"]:
        events.append(Event(cnr, "status_changed", record.status))
    return events
