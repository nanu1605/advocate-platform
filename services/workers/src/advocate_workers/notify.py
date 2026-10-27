"""Notification rows (spec §13): who gets them, what they say in Hindi and English, and the keys that stop retries
notifying twice. Rows only: push (FCM) waits for Track B and Windows toasts are app work (task 11), so nothing here
delivers and no notification_deliveries rows are written. By default a notification names only the case number and
court position, never parties or clients (§13.2); notification_prefs.include_titles adds the case title. `data`
carries the kind, ids, a deep link, the event key, a collapse key and the facts, so the app can re-render it."""

import asyncio
import json
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import date, datetime, time
from typing import Any, Literal
from uuid import UUID

import structlog
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from advocate_shared.ist import IST, now_ist
from advocate_workers import db
from advocate_workers.celery_app import DEADLINE_REMINDERS, app
from advocate_workers.diff import Event

log = structlog.get_logger()

EN_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
HI_DAYS = ["सोम", "मंगल", "बुध", "गुरु", "शुक्र", "शनि", "रवि"]
EN_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
HI_MONTHS = ["जनवरी", "फ़रवरी", "मार्च", "अप्रैल", "मई", "जून", "जुलाई", "अगस्त", "सितंबर", "अक्टूबर", "नवंबर", "दिसंबर"]
TITLES = {
    "tomorrow_board": ("Tomorrow's board", "कल का बोर्ड"),
    "today_morning": ("Today", "आज"),
    "listed_unexpectedly": ("Listed early", "जल्दी सूचीबद्ध"),
    "new_order": ("New order", "नया आदेश"),
    "next_date_set": ("Next date", "अगली तारीख"),
    "status_changed": ("Case status", "केस की स्थिति"),
    "sync_issue": ("Court data delayed", "कोर्ट डेटा में देरी"),
    "deadline_due": ("Deadline", "समय-सीमा"),
}
# deadlines.kind as a deadline_due body names it (the app's casesDeadline* words).
DEADLINE_KINDS = {
    "limitation": ("limitation", "परिसीमा"),
    "compliance": ("compliance", "अनुपालन"),
    "filing": ("filing", "फ़ाइलिंग"),
    "other": ("deadline", "समय-सीमा"),
}


@dataclass(frozen=True, slots=True)
class Recipient:
    user_id: UUID
    lang: str  # profiles.preferred_language: "hi" or "en"
    include_titles: bool


@dataclass(frozen=True, slots=True)
class Position:
    """Where a matter is heard: "MPHC Indore, Court 12, item 23" / "MPHC इंदौर, कोर्ट 12, आइटम 23"."""

    short_name: str | None = None
    short_name_hi: str | None = None
    court_no: str | None = None
    item_no: str | None = None

    def text(self, lang: str) -> str:
        hi = lang == "hi"
        parts = [(self.short_name_hi or self.short_name) if hi else self.short_name]
        if self.court_no:
            parts.append(f"कोर्ट {self.court_no}" if hi else f"Court {self.court_no}")
        if self.item_no:
            parts.append(f"आइटम {self.item_no}" if hi else f"item {self.item_no}")
        return ", ".join(p for p in parts if p)


def day_text(d: date, lang: str) -> str:
    """ "Thu 5 Nov" / "गुरु, 5 नवंबर"."""
    if lang == "hi":
        return f"{HI_DAYS[d.weekday()]}, {d.day} {HI_MONTHS[d.month - 1]}"
    return f"{EN_DAYS[d.weekday()]} {d.day} {EN_MONTHS[d.month - 1]}"


def time_text(t: time, lang: str) -> str:
    """ "8:30 pm" / "रात 8:30 बजे"."""
    clock = f"{t.hour % 12 or 12}" + (f":{t.minute:02d}" if t.minute else "")
    if lang == "hi":
        period = "सुबह" if 4 <= t.hour < 12 else "दोपहर" if t.hour < 16 else "शाम" if t.hour < 20 else "रात"
        return f"{period} {clock} बजे"
    return f"{clock} {'am' if t.hour < 12 else 'pm'}"


def case_label(matter: Mapping[str, Any], include_titles: bool = False) -> str:
    """ "WP 1234/2024" from case_type, case_number and case_year; the CNR when there is no number, else the office's
    file number (a manual case may have neither). The title (party names) only when the user turned on "Include case
    titles". Empty when there is nothing to name it by."""
    number, year = matter.get("case_number"), matter.get("case_year")
    if number:
        label = " ".join(str(p) for p in (matter.get("case_type"), f"{number}/{year}" if year else number) if p)
    else:
        label = matter.get("cnr") or matter.get("file_no") or ""
    title = matter.get("title") if include_titles else None
    return " · ".join(p for p in (label, title) if p)


async def recipients(conn: AsyncConnection, org_id: UUID | str, kind: str) -> list[Recipient]:
    """Active members of the organisation, minus those who turned this kind off (a prefs row with no channels)."""
    found = await db.rows(
        conn,
        "select ms.user_id, p.preferred_language as lang, coalesce(np.include_titles, false) as include_titles "
        "from public.memberships ms join public.profiles p on p.id = ms.user_id "
        "left join public.notification_prefs np on np.user_id = ms.user_id and np.kind = :k "
        "where ms.org_id = :o and ms.status = 'active' and (np.id is null or cardinality(np.channels) > 0)",
        o=org_id,
        k=kind,
    )
    return [Recipient(**r) for r in found]


INSERT = """
insert into public.notifications (org_id, user_id, kind, title, body, data)
values (:o, :u, :k, :t, :b, cast(:d as jsonb))
on conflict (user_id, (data->>'event_key'))"""
# Rewrites only a changed message, so devices don't re-sync (and toast) an unchanged one.
REPLACE = """ do update set title = excluded.title, body = excluded.body, data = excluded.data
where (notifications.title, notifications.body, notifications.data)
  is distinct from (excluded.title, excluded.body, excluded.data)"""
# Rewrites a message already written (when changed), never adding one.
UPDATE = """
update public.notifications set title = :t, body = :b, data = cast(:d as jsonb)
where user_id = :u and data->>'event_key' = :key
  and (title, body, data) is distinct from (cast(:t as text), cast(:b as text), cast(:d as jsonb))"""


async def write(
    conn: AsyncConnection,
    org_id: UUID | str,
    kind: str,
    key: str,
    body: Callable[[Recipient], str],
    data: dict[str, Any],
    *,
    replace: bool = False,
    update_only: bool = False,
) -> int:
    """One row per recipient, keyed (user, `key`). A retry with the same key is skipped, or with `replace` rewrites
    the row when it changed (one board message per evening, §13.2); `update_only` rewrites only the rows already
    written, adding none. Returns the rows written."""
    payload = json.dumps({"kind": kind, "org_id": str(org_id), "event_key": key, **data}, default=str)
    written = 0
    for who in await recipients(conn, org_id, kind):
        result = await conn.execute(
            text(UPDATE if update_only else INSERT + (REPLACE if replace else " do nothing")),
            {
                "o": org_id,
                "u": who.user_id,
                "k": kind,
                "t": TITLES[kind][who.lang == "hi"],
                "b": body(who),
                "d": payload,
                "key": key,
            },
        )
        written += result.rowcount  # type: ignore[attr-defined]
    return written


def _case_data(matter: Mapping[str, Any], event: Event) -> dict[str, Any]:
    facts = {"next_date_set": "date", "new_order": "provider_ref", "status_changed": "status"}
    return {
        "matter_id": str(matter["id"]),
        "link": f"/cases/{matter['id']}",
        "collapse_key": f"{event.kind}:{matter['id']}",
        facts[event.kind]: event.value,
    }


async def case_event(conn: AsyncConnection, matter: Mapping[str, Any], event: Event) -> int:
    """next_date_set, new_order or status_changed for one tracking matter (fanout.live_matters row)."""
    if event.kind == "new_order":
        return await new_order(conn, matter, event)

    def body(who: Recipient) -> str:
        label, hi = case_label(matter, who.include_titles), who.lang == "hi"
        if event.kind == "next_date_set":
            when = day_text(date.fromisoformat(event.value), who.lang)
            return f"{label}: अगली तारीख {when}।" if hi else f"{label}: next date {when}."
        if hi:
            return f"{label} {'निराकृत' if event.value == 'disposed' else 'स्थानांतरित'} दर्ज किया गया।"
        return f"{label} marked {event.value}."

    return await write(conn, matter["org_id"], event.kind, event.key, body, _case_data(matter, event))


async def new_order(conn: AsyncConnection, matter: Mapping[str, Any], event: Event, actions: int = 0) -> int:
    """ "New order in WP 1234/2024." when the court records it; once order intelligence has proposed `actions` tasks
    and deadlines, the same message (event key) is rewritten "New order in WP 1234/2024 — 2 actions found." (§13.1).
    Only a message already written is: an order never notified as new (a case's first fetch, §13.1) gets none."""

    def body(who: Recipient) -> str:
        label = case_label(matter, who.include_titles)
        if who.lang == "hi":
            found = f" — {actions} काम {'मिला' if actions == 1 else 'मिले'}" if actions else ""
            return f"{label} में नया आदेश{found}।"
        found = f" — {actions} action{'s' * (actions != 1)} found" if actions else ""
        return f"New order in {label}{found}."

    data = _case_data(matter, event) | ({"actions": actions} if actions else {})
    return await write(conn, matter["org_id"], "new_order", event.key, body, data, update_only=bool(actions))


async def listed_unexpectedly(
    conn: AsyncConnection, matter: Mapping[str, Any], list_date: date, position: Position
) -> int:
    """A tracked case on tomorrow's cause list before its court next date (advocate_watch, §11.5)."""

    def body(who: Recipient) -> str:
        label, where = case_label(matter, who.include_titles), position.text(who.lang)
        if who.lang == "hi":
            return f"{label} कल सूचीबद्ध है (अपेक्षा से पहले)।" + (f" {where}।" if where else "")
        return f"{label} is listed tomorrow (earlier than expected)." + (f" {where}." if where else "")

    key = f"{matter['cnr']}:listed_unexpectedly:{list_date}"
    data = {
        "matter_id": str(matter["id"]),
        "link": f"/cases/{matter['id']}",
        "collapse_key": f"listed_unexpectedly:{matter['id']}",
        "list_date": list_date,
        "court_no": position.court_no,
        "item_no": position.item_no,
    }
    return await write(conn, matter["org_id"], "listed_unexpectedly", key, body, data)


BOARD = """
select count(*) as matters, count(distinct coalesce(b.court_id::text, '')) as courts,
       (array_agg(json_build_object('short_name', c.short_name, 'short_name_hi', c.short_name_hi,
                                    'court_no', b.court_no, 'item_no', b.item_no)
        order by b.expected_slot nulls last, c.short_name,
                 nullif(regexp_replace(b.court_no, '\\D', '', 'g'), '')::numeric,
                 nullif(regexp_replace(b.item_no, '\\D', '', 'g'), '')::numeric nulls last))[1] as first
from public.board_entries b
join public.matters m on m.id = b.matter_id and m.deleted_at is null
left join public.courts c on c.id = b.court_id
where b.org_id = :o and b.board_date = :d and b.is_current
"""


async def board_summary(
    conn: AsyncConnection, kind: Literal["tomorrow_board", "today_morning"], org_id: UUID | str, board_date: date
) -> int:
    """The evening "Tomorrow: 6 matters in 3 courts. First: MPHC Indore, Court 12, item 23." or the 07:30 "Today: 4
    matters. First at MPHC Indore, Court 7." from the organisation's board_entries for `board_date`. One message per
    organisation and date: a later attempt rewrites it. Nothing is written for an empty board, and a board emptied
    by a later attempt takes back the message it had (rather than leave a wrong count)."""
    key = f"{kind}:{org_id}:{board_date}"
    [summary] = await db.rows(conn, BOARD, o=org_id, d=board_date)
    n, courts = summary["matters"], summary["courts"]
    if not n:
        await conn.execute(
            text("delete from public.notifications where org_id = :o and data->>'event_key' = :k"),
            {"o": org_id, "k": key},
        )
        return 0
    first = Position(**summary["first"])

    def body(who: Recipient) -> str:
        where = first.text(who.lang)
        if kind == "tomorrow_board":
            if who.lang == "hi":
                return f"कल: {courts} कोर्ट में {n} केस।" + (f" पहला: {where}।" if where else "")
            counts = f"{n} matter{'s' * (n != 1)} in {courts} court{'s' * (courts != 1)}"
            return f"Tomorrow: {counts}." + (f" First: {where}." if where else "")
        if who.lang == "hi":
            return f"आज: {n} केस।" + (f" पहला: {where}।" if where else "")
        return f"Today: {n} matter{'s' * (n != 1)}." + (f" First at {where}." if where else "")

    link = "/board/tomorrow" if kind == "tomorrow_board" else "/today"
    data = {"link": link, "collapse_key": f"{kind}:{org_id}", "board_date": board_date, "matters": n, "courts": courts}
    return await write(conn, org_id, kind, key, body, data, replace=True)


async def sync_issue(conn: AsyncConnection, org_id: UUID | str, day: date, retry_at: time | None = None) -> int:
    """ "Court data is delayed. We'll retry at 8:30 pm." Once per organisation per day (§13.1)."""

    def body(who: Recipient) -> str:
        if who.lang == "hi":
            then = (
                f"हम {time_text(retry_at, 'hi')} फिर कोशिश करेंगे।"
                if retry_at
                else "कल का बोर्ड आखिरी मिली तारीखों से बना है।"
            )
            return f"कोर्ट डेटा में देरी है। {then}"
        then = (
            f"We'll retry at {time_text(retry_at, 'en')}."
            if retry_at
            else "Tomorrow's board uses the last known dates."
        )
        return f"Court data is delayed. {then}"

    data = {"link": "/today", "collapse_key": f"sync_issue:{org_id}", "day": day}
    return await write(conn, org_id, "sync_issue", f"sync_issue:{org_id}:{day}", body, data)


DUE = """
select d.id, d.org_id, d.matter_id, d.kind, d.due_date, d.due_date - cast(:d as date) as days,
       m.case_type, m.case_number, m.case_year, m.cnr, m.file_no, m.title, m.court_no, c.short_name, c.short_name_hi
from public.deadlines d
join public.matters m on m.id = d.matter_id and m.deleted_at is null
left join public.courts c on c.id = m.court_id
where d.status = 'active' and d.deleted_at is null and d.due_date >= cast(:d as date)
  and d.due_date - cast(:d as date) = any(d.reminder_offsets)
order by d.org_id, d.due_date
"""


async def deadline_due(conn: AsyncConnection, deadline: Mapping[str, Any]) -> int:
    """ "WP 1234/2024, MPHC Indore, Court 12: filing due in 3 days (Thu 29 Oct)." for a DUE row, `days` (one of its
    reminder_offsets) before its due date. Keyed per deadline and offset, so each reminder is written once; they share
    a collapse key, so the newest replaces the earlier ones. The app lets the day-of one break quiet hours
    (data.due_date is today, ADR 0017)."""
    days, due = deadline["days"], deadline["due_date"]
    court = Position(deadline["short_name"], deadline["short_name_hi"], deadline["court_no"])

    def body(who: Recipient) -> str:
        hi = who.lang == "hi"
        label, at = case_label(deadline, who.include_titles), court.text(who.lang)
        if label:
            where = ", ".join(p for p in (label, at) if p)
        else:  # a manual case with only a title, which names parties: its court says which
            where = (f"{at} का एक केस" if at else "एक केस") if hi else (f"A case at {at}" if at else "A case")
        what = DEADLINE_KINDS.get(deadline["kind"], DEADLINE_KINDS["other"])[hi]
        on = day_text(due, who.lang)
        if hi:
            when = "आज" if days == 0 else f"कल ({on})" if days == 1 else f"{days} दिन में ({on})"
            return f"{where}: {what} की आखिरी तारीख {when}।"
        when = "today" if days == 0 else f"tomorrow ({on})" if days == 1 else f"in {days} days ({on})"
        return f"{where}: {what} due {when}."

    data = {
        "matter_id": str(deadline["matter_id"]),
        "deadline_id": str(deadline["id"]),
        "link": f"/cases/{deadline['matter_id']}?tab=notes",  # deadlines are listed under Notes & tasks
        "collapse_key": f"deadline_due:{deadline['id']}",
        "due_date": due,
        "days": days,
    }
    return await write(conn, deadline["org_id"], "deadline_due", f"deadline_due:{deadline['id']}:{days}", body, data)


async def run_deadline_due(now: datetime) -> int:
    """07:30 IST: deadline_due to every member (like the other kinds; clerks see deadlines too, §15.3) for each active
    deadline on a live case due in one of its reminder_offsets days (default 3, 1, 0) from today in IST. A re-run
    writes nothing new. A deadline with no case gets none (the app always files one under a case). Returns the
    notifications written."""
    # ponytail: a morning the beat misses is not caught up, and a moved due date keeps the reminders sent for the old
    # one (the key has no date); look back a few days and key on due_date if deadlines become editable.
    written = 0
    async with db.engine().begin() as c:
        for deadline in await db.rows(c, DUE, d=now.astimezone(IST).date()):
            try:
                async with c.begin_nested():
                    written += await deadline_due(c, deadline)
            except Exception:
                log.exception("deadline_due_failed", deadline_id=str(deadline["id"]))  # the others still get theirs
    return written


@app.task(name=DEADLINE_REMINDERS)
def deadline_reminders() -> int:
    return asyncio.run(run_deadline_due(now_ist()))
