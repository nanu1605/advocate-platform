"""Fan-out (spec §11.6): copy a CNR's shared court rows into every organisation that tracks it, then notify.

Only live (deleted_at is null), auto-tracked matters take court data. Hearings and orders are keyed on the court row
they came from, so a re-run updates them in place, and a restored matter gets its court rows back (deleted_at
cleared). User columns (user_next_date, user_purpose, user_outcome, user_note, confirmed) are never touched. Rows are
rewritten only when a value changed, so devices don't re-sync unchanged data."""

from collections.abc import Sequence
from typing import Any
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_workers import db, notify
from advocate_workers.diff import LOCK_MATTERS, Event

LIVE_MATTERS = """
select m.id, m.org_id, m.cnr, m.case_type, m.case_number, m.case_year, m.title, m.court_id, m.court_no,
       c.short_name, c.short_name_hi
from public.matters m left join public.courts c on c.id = m.court_id
where m.cnr = :cnr and m.tracking = 'auto' and m.deleted_at is null
"""
SYNC_MATTERS = """
with c as (
  select cc.*, (select max(o.order_date) from public.court_orders o where o.cnr = cc.cnr) as last_order
  from public.court_cases cc where cc.cnr = :cnr
)
update public.matters m set court_status = c.status, next_hearing_date = c.next_hearing_date, stage = c.stage,
  judge = c.judge, court_no = c.court_no, last_order_date = c.last_order, court_fetched_at = c.fetched_at,
  case_type = coalesce(c.case_type, m.case_type), case_number = coalesce(c.case_number, m.case_number),
  case_year = coalesce(c.case_year, m.case_year), title = coalesce(c.title, m.title),
  court_id = coalesce(c.court_id, m.court_id)
from c
where m.cnr = c.cnr and m.tracking = 'auto' and m.deleted_at is null
  and (m.court_status, m.next_hearing_date, m.stage, m.judge, m.court_no, m.last_order_date, m.court_fetched_at,
       m.case_type, m.case_number, m.case_year, m.title, m.court_id)
  is distinct from (c.status, c.next_hearing_date, c.stage, c.judge, c.court_no, c.last_order, c.fetched_at,
       coalesce(c.case_type, m.case_type), coalesce(c.case_number, m.case_number), coalesce(c.case_year, m.case_year),
       coalesce(c.title, m.title), coalesce(c.court_id, m.court_id))
"""
SYNC_HEARINGS = """
insert into public.hearings (org_id, matter_id, court_hearing_id, date, purpose, outcome, next_date, source)
select m.org_id, m.id, h.id, h.hearing_date, h.purpose, h.business, h.next_date, 'court'
from public.matters m join public.court_hearings h on h.cnr = m.cnr
where m.cnr = :cnr and m.tracking = 'auto' and m.deleted_at is null
on conflict (matter_id, court_hearing_id) do update set date = excluded.date, purpose = excluded.purpose,
  outcome = excluded.outcome, next_date = excluded.next_date, deleted_at = null
where (hearings.date, hearings.purpose, hearings.outcome, hearings.next_date, hearings.deleted_at)
  is distinct from (excluded.date, excluded.purpose, excluded.outcome, excluded.next_date, null)
"""
# The title is the order type (order, judgment, interim); the app shows it in the user's language.
SYNC_ORDERS = """
insert into public.orders (org_id, matter_id, court_order_id, order_date, title)
select m.org_id, m.id, o.id, o.order_date, o.order_type
from public.matters m join public.court_orders o on o.cnr = m.cnr
where m.cnr = :cnr and m.tracking = 'auto' and m.deleted_at is null
on conflict (matter_id, court_order_id) do update set order_date = excluded.order_date, title = excluded.title,
  deleted_at = null
where (orders.order_date, orders.title, orders.deleted_at) is distinct from (excluded.order_date, excluded.title, null)
"""


async def live_matters(conn: AsyncConnection, cnr: str) -> list[dict[str, Any]]:
    """The live, auto-tracked matters with this CNR, with what notify needs (case label fields, court names)."""
    return await db.rows(conn, LIVE_MATTERS, cnr=cnr)


async def fan_out(conn: AsyncConnection, cnr: str, events: Sequence[Event] = ()) -> list[UUID]:
    """Sync every tracking matter from the cached court tables, then notify their organisations of `events`. With
    no events it only syncs (e.g. a new matter whose CNR is already cached). Returns the court_orders ids of new
    orders that someone tracks: enqueue ORDER_PIPELINE for them after the transaction commits."""
    for statement in (LOCK_MATTERS, SYNC_MATTERS, SYNC_HEARINGS, SYNC_ORDERS):  # LOCK_MATTERS first: see diff.py
        await conn.execute(text(statement), {"cnr": cnr})
    matters = await live_matters(conn, cnr)
    for event in events:
        for matter in matters:
            await notify.case_event(conn, matter, event)
    if not matters:
        return []
    return [e.court_order_id for e in events if e.kind == "new_order" and e.court_order_id]
