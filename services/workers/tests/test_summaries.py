"""Order summaries, order intelligence and proposals (spec §4.4 F07, F13, §12.8, §12.14, ADR 0023): the automatic
pipeline after a court order's text is read, and the on-demand jobs. The model is legal_ai.fake.Scripted."""

import asyncio
import json
from collections.abc import AsyncIterator, Callable
from datetime import UTC, date, datetime
from decimal import Decimal
from typing import Any

import pytest
from conftest import Factory, Org, sql

from advocate_shared import ai, order_ai
from advocate_shared.settings import get_settings
from advocate_workers import db, doctext, jobs, notify, summaries
from advocate_workers.celery_app import ORDER_AI
from advocate_workers.diff import Event
from advocate_workers.fanout import fan_out
from legal_ai.config import load_config
from legal_ai.fake import Scripted
from legal_ai.llm import CallFailed, LLMClient, Unavailable

TODAY = date(2026, 10, 26)
MADE_ON = date(2026, 10, 20)
INDIA = {f"BEDROCK_PROFILE_{t.upper()}": f"in.local.{t}" for t in ("fast", "standard", "deep")}
PAGES = {1: "1. Heard counsel for the petitioner. Notice issued.", 3: "3. Respondents shall file a reply."}
NUMBERED = {"case_type": "WP", "case_number": "1234", "case_year": 2024}


def summary(gist: str, order_date: str | None = None) -> str:
    return json.dumps({
        "title": "Ramesh Kumar v. State of MP", "court": "MPHC Indore", "order_date": order_date, "judges": [],
        "header_sources": ["S1"], "outcome": None, "gist": {"text": gist, "sources": ["S2"]}, "directions": [],
        "next_date": None, "relief": None, "key_reasons": [], "authorities_cited_in_document": [],
        "next_steps_for_us": [],
    })  # fmt: skip


WITHIN_4_WEEKS = {"within": 4, "unit": "weeks"}
INTEL = json.dumps({"actions": [
    {"kind": "deadline", "title": "Respondents to file reply", "due": WITHIN_4_WEEKS, "sources": ["S2"]},
    {"kind": "task", "title": "Petitioner to serve notice", "due": None, "sources": ["S1"]},
    {"kind": "deadline", "title": "Deposit costs", "due": None, "sources": ["S1"]},  # no date: a task
    {"kind": "task", "title": "File compliance report", "due": {"on": "2026-11-30"}, "sources": ["S1"]},
]})  # fmt: skip
INTEL_HI = json.dumps({"actions": [
    {"kind": "deadline", "title": "प्रतिवादी जवाब दाखिल करें", "due": WITHIN_4_WEEKS, "sources": ["S2"]},
    {"kind": "task", "title": "याचिकाकर्ता नोटिस तामील करें", "due": None, "sources": ["S1"]},
]})  # fmt: skip
STORED_INTEL = json.loads(INTEL) | {"order_date": "2026-10-20", "source_pages": {"S1": 1, "S2": 3}}


@pytest.fixture(autouse=True)
def no_platform_budget(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(get_settings(), "ai_platform_daily_budget_inr", None)


@pytest.fixture
def model(monkeypatch: pytest.MonkeyPatch) -> Callable[..., Scripted]:
    """`model(reply, …)`: the model replies these in order (a call past them fails the test)."""

    def script(*replies: str | Exception) -> Scripted:
        transport = Scripted(replies)
        client = LLMClient(load_config(env=INDIA), transport)
        monkeypatch.setattr(ai, "configured_llm", lambda: client)
        return transport

    return script


@pytest.fixture
async def court_order(make: Factory) -> AsyncIterator[Callable[..., Any]]:
    """`await court_order(made_on=…, status='text', pages=PAGES)` -> (court order id, cnr): read into chunks (page 2
    blank). Its shared summaries are removed after (public_summaries is not cascaded)."""
    made: list[str] = []

    async def create(made_on: date | None = MADE_ON, status: str = "text", pages: dict[int, str] = PAGES):
        cnr = make.cnr()
        [row] = await sql(
            "insert into public.court_orders (cnr, provider_ref, order_date, text_status, pages) "
            "values (:c, 'order-2.pdf', :d, :s, 3) returning id::text",
            c=cnr, d=made_on, s=status,
        )  # fmt: skip
        for page_no, text in pages.items():
            await sql(
                "insert into public.document_chunks (court_order_id, page_no, chunk_no, text) values (:id, :p, 0, :t)",
                id=row["id"], p=page_no, t=text,
            )  # fmt: skip
        made.append(row["id"])
        return row["id"], cnr

    yield create
    await sql("delete from public.public_summaries where doc_ref = any(:r)", r=made)


async def track(make: Factory, cnr: str, *orgs: Org) -> dict[str, str]:
    """Each org auto-tracks the case (WP 1234/2024) and gets its orders rows, as fan-out makes them: {org: order}."""
    for org in orgs:
        await make.matter(org, cnr, **NUMBERED)
    async with db.engine().begin() as c:
        await fan_out(c, cnr)
    rows = await sql(
        "select o.org_id::text, o.id::text from public.orders o join public.matters m on m.id = o.matter_id "
        "where o.org_id = any(cast(:o as uuid[])) and m.cnr = :c",
        o=[o.id for o in orgs], c=cnr,
    )  # fmt: skip
    return {r["org_id"]: r["id"] for r in rows}


async def runs(org_id: str) -> list[tuple[Any, ...]]:
    """(kind, status, ledger kind, quantity) of the organisation's AI runs, oldest first."""
    found = await sql(
        "select r.kind, r.status, l.kind as billed, l.quantity from public.ai_runs r "
        "left join public.usage_ledger l on l.ref_id = r.id where r.org_id = :o order by r.created_at",
        o=org_id,
    )
    return [(r["kind"], r["status"], r["billed"], r["quantity"]) for r in found]


async def over_cap(org: Org) -> None:
    await sql("insert into public.usage_ledger (org_id, kind, cost_inr) values (:o, 'ai_automatic', 40)", o=org.id)


def asked(transport: Scripted) -> list[tuple[str, str]]:
    """(task, output language) of each model call."""
    return [(task, "hi" if "Output language: Hindi." in req["system"][0]["text"] else "en")
            for task, req in transport.requests]  # fmt: skip


# ---------------------------------------------------------------- pages


def test_pages_are_rebuilt_exactly_from_overlapping_chunks():
    long_page = " ".join(f"शब्द{i} word{i}" for i in range(900))
    pages = [long_page, "", "Short   page\n\n three."]
    chunks = doctext.chunks(pages)
    assert sum(c.page_no == 1 for c in chunks) > 3  # several overlapping chunks
    sources = order_ai.join_pages((c.page_no, c.text) for c in chunks)
    assert [(s.page, s.text) for s in sources] == [(1, long_page), (3, "Short page\nthree.")]


# ---------------------------------------------------------------- the automatic pipeline


async def test_summaries_in_every_members_language_made_once_and_billed_to_the_oldest_org(
    make: Factory, court_order, model, r
):
    co, cnr = await court_order(made_on=date(2026, 8, 1))  # old: summaries only
    first = await make.org("Neha Sharma", members={"Rakesh Jain": ("advocate", "hi")})
    second = await make.org("Arun Mehta")
    orders = await track(make, cnr, first, second)
    transport = model(summary("Notice issued."), summary("नोटिस जारी।"))

    assert await summaries.pipeline(r, co, TODAY) == "done"
    assert asked(transport) == [("order_summary", "en"), ("order_summary", "hi")]
    assert (
        '<source id="S2" kind="order" page="3">3. Respondents shall file a reply.</source>'
        in (transport.requests[0][1]["messages"][0]["content"][0]["text"])
    )  # one source per page, blank page 2 left out
    for order_id in orders.values():
        [row] = await sql("select summary_en, summary_hi from public.orders where id = :id", id=order_id)
        assert row["summary_en"]["gist"] == {"text": "Notice issued.", "sources": ["S2"]}
        assert row["summary_hi"]["source_pages"] == {"S1": 1, "S2": 3}
    assert await runs(first.id) == [("order_summary", "ok", "ai_automatic", 1)] * 2
    assert await runs(second.id) == []  # reads it free (ADR 0020)

    assert await summaries.pipeline(r, co, TODAY) == "done"  # a redelivery: cached, nothing paid again
    later = await make.org("Kavita Rao")  # starts tracking afterwards: its new orders row comes with them
    [late] = (await track(make, cnr, later)).values()
    [row] = await sql("select summary_en->'gist'->>'text' as en, summary_hi is not null as hi from public.orders "
                      "where id = :id", id=late)  # fmt: skip
    assert row == {"en": "Notice issued.", "hi": True}


async def test_an_org_tracking_by_hand_or_that_deleted_the_case_neither_pays_nor_adds_a_language(
    make: Factory, court_order, model, r
):
    co, cnr = await court_order(made_on=date(2026, 8, 1))
    manual = await make.org("Sita Verma", lang="hi")  # oldest, within its cap, and the only ones reading Hindi
    deleted = await make.org("Kavita Rao", lang="hi")
    await make.matter(manual, cnr, tracking="manual")
    await make.matter(deleted, cnr, deleted=True)
    auto = await make.org("Arun Mehta")
    await track(make, cnr, auto)
    transport = model(summary("Notice issued."))

    assert await summaries.pipeline(r, co, TODAY) == "done"
    assert asked(transport) == [("order_summary", "en")]
    assert await runs(auto.id) == [("order_summary", "ok", "ai_automatic", 1)]
    assert await runs(manual.id) == [] and await runs(deleted.id) == []


async def test_the_first_org_within_its_cap_pays_others_wait_or_ask_on_demand(
    make: Factory, court_order, model, r, monkeypatch
):
    co, cnr = await court_order(made_on=date(2026, 8, 1))
    capped, within = await make.org("Neha Sharma"), await make.org("Arun Mehta")
    await track(make, cnr, capped, within)
    await over_cap(capped)

    monkeypatch.setattr(get_settings(), "ai_platform_daily_budget_inr", Decimal(0))  # spent for today
    model()
    assert await summaries.pipeline(r, co, TODAY) == "later"

    monkeypatch.setattr(get_settings(), "ai_platform_daily_budget_inr", None)
    model(summary("Notice issued."))
    assert await summaries.pipeline(r, co, TODAY) == "done"
    assert await runs(capped.id) == []
    assert [k for k, *_ in await runs(within.id)] == ["order_summary"]

    co2, cnr2 = await court_order(made_on=date(2026, 8, 1))
    await track(make, cnr2, capped)
    model()  # over its cap: left to its members, on demand (§12.14)
    assert await summaries.pipeline(r, co2, TODAY) == "done"
    assert await sql("select 1 from public.public_summaries where doc_ref = :r", r=co2) == []


async def test_a_summary_another_run_is_making_is_skipped_and_its_intel_retried(make: Factory, court_order, model, r):
    co, cnr = await court_order()
    org = await make.org()
    await track(make, cnr, org)
    held = [f"ai:order_summary:{co}:en", f"ai:order_intel:{co}:en"]
    for key in held:
        await r.set(key, "another-run", ex=60)
    try:
        model()
        assert await order_ai.summarise(db.engine().begin, r, "court_order", co, "en", org_id=org.id,
                                        billing="automatic") is None  # fmt: skip
        assert await summaries.pipeline(r, co, TODAY) == "later"  # the intel's holder proposes for itself only
        assert await runs(org.id) == []
    finally:
        await r.delete(*held)


async def test_intel_only_for_recent_orders_and_the_date_may_come_from_the_summary(
    make: Factory, court_order, model, r
):
    old, cnr = await court_order(made_on=date(2026, 9, 25))  # 31 days
    org = await make.org()
    await track(make, cnr, org)
    model(summary("Notice issued."))
    assert await summaries.pipeline(r, old, TODAY) == "done"  # no intel asked for

    undated, cnr2 = await court_order(made_on=None)
    await track(make, cnr2, org)
    transport = model(summary("Notice issued.", order_date="2026-10-20"), json.dumps({"actions": []}))
    assert await summaries.pipeline(r, undated, TODAY) == "done"
    assert [task for task, _ in asked(transport)] == ["order_summary", "order_intel"]
    assert "dated 2026-10-20" in transport.requests[1][1]["messages"][0]["content"][0]["text"]
    [stored] = await sql("select summary from public.public_summaries where doc_kind = 'order_intel' "
                         "and doc_ref = :r", r=undated)  # fmt: skip
    assert stored["summary"] == {"actions": [], "order_date": "2026-10-20", "source_pages": {"S1": 1, "S2": 3}}


async def test_proposals_per_org_in_its_owners_language_never_duplicating_and_counted_in_the_message(
    make: Factory, court_order, model, r
):
    co, cnr = await court_order()
    hindi = await make.org("Rakesh Jain", lang="hi", members={"Neha Sharma": ("advocate", "en")})
    english = await make.org("Arun Mehta", members={"Sita Verma": ("junior", "hi")})
    orders = await track(make, cnr, hindi, english)
    [matter] = await sql("select id::text from public.matters where org_id = :o", o=english.id)
    await sql(
        "insert into public.tasks (org_id, matter_id, title, status) values "
        "(:o, :m, 'petitioner to  SERVE notice', 'open'), (:o, :m, 'Deposit costs', 'done')",
        o=english.id, m=matter["id"],
    )  # fmt: skip
    event = Event(cnr, "new_order", "order-2.pdf")
    async with db.engine().begin() as c:  # what fan-out wrote when the order came
        for org in (hindi, english):
            [row] = await db.rows(c, "select * from public.matters where org_id = :o", o=org.id)
            await notify.case_event(c, row, event)
    transport = model(summary("Notice issued."), summary("नोटिस जारी।"), INTEL, INTEL)

    assert await summaries.pipeline(r, co, TODAY) == "done"
    assert asked(transport)[2:] == [("order_intel", "en"), ("order_intel", "hi")]  # each owner's language
    deadlines = await sql(
        "select org_id::text, kind, due_date, basis, source_order_id::text, status, dedupe_key "
        "from public.deadlines where org_id = any(cast(:o as uuid[])) order by org_id", o=[hindi.id, english.id]
    )  # fmt: skip
    assert len(deadlines) == 2
    for d in deadlines:
        assert (d["kind"], d["due_date"], d["status"], d["source_order_id"]) == (
            "compliance", date(2026, 11, 17), "proposed", orders[d["org_id"]])  # fmt: skip
        assert d["basis"] == {"title": "Respondents to file reply", "due": {"on": None, "within": 4, "unit": "weeks"},
                              "order_date": "2026-10-20", "pages": [3], "verify": True}  # fmt: skip
        assert d["dedupe_key"].startswith(f"order:{co}:")
    tasks = await sql(
        "select title, due_at, source, source_ref, status from public.tasks where org_id = :o and status = 'proposed' "
        "order by title", o=hindi.id
    )  # fmt: skip
    assert tasks == [
        {"title": "Deposit costs", "due_at": None, "source": "order", "source_ref": orders[hindi.id],
         "status": "proposed"},
        {"title": "File compliance report", "due_at": datetime(2026, 11, 29, 18, 30, tzinfo=UTC), "source": "order",
         "source_ref": orders[hindi.id], "status": "proposed"},  # IST midnight
        {"title": "Petitioner to serve notice", "due_at": None, "source": "order", "source_ref": orders[hindi.id],
         "status": "proposed"},
    ]  # fmt: skip
    english_new = await sql("select title from public.tasks where org_id = :o and status = 'proposed'", o=english.id)
    assert english_new == [{"title": "File compliance report"}]  # the other two it has already

    sent = await sql("select body from public.notifications where org_id = any(cast(:o as uuid[]))",
                     o=[hindi.id, english.id])  # fmt: skip
    bodies = {n["body"] for n in sent}
    assert bodies == {
        "New order in WP 1234/2024 — 4 actions found.", "WP 1234/2024 में नया आदेश — 4 काम मिले।",
        "New order in WP 1234/2024 — 2 actions found.", "WP 1234/2024 में नया आदेश — 2 काम मिले।",
    }  # fmt: skip
    [data] = await sql("select data from public.notifications where user_id = :u", u=english.owner_id)
    assert (data["data"]["actions"], data["data"]["event_key"]) == (2, event.key)  # the same message, rewritten

    assert await summaries.pipeline(r, co, TODAY) == "done"  # a redelivery proposes nothing twice
    [n] = await sql("select count(*) as n from public.tasks where org_id = :o", o=hindi.id)
    assert n["n"] == 3


async def test_the_count_rewrites_a_new_order_message_and_never_adds_one(make: Factory):
    org = await make.org("Arun Mehta", members={"Sita Verma": ("junior", "hi")})
    cnr = make.cnr()
    matter = {"id": await make.matter(org, cnr, **NUMBERED), "org_id": org.id, **NUMBERED}
    event, other = Event(cnr, "new_order", "o1"), Event(cnr, "new_order", "o2")
    async with db.engine().begin() as c:
        await notify.new_order(c, matter, other)  # another order's message stays as it is
        assert await notify.new_order(c, matter, event, 2) == 0  # never notified as new (a case's first fetch)
        await notify.new_order(c, matter, event)
        assert await notify.new_order(c, matter, event, 1) == 2
    rows = await sql("select data->>'event_key' as key, body from public.notifications where org_id = :o", o=org.id)
    assert {(n["key"].rsplit(":", 1)[1], n["body"]) for n in rows} == {
        ("o1", "New order in WP 1234/2024 — 1 action found."),
        ("o1", "WP 1234/2024 में नया आदेश — 1 काम मिला।"),
        ("o2", "New order in WP 1234/2024."),
        ("o2", "WP 1234/2024 में नया आदेश।"),
    }


async def test_a_proposal_is_skipped_only_for_a_live_task_or_deadline_with_its_title_and_day(
    make: Factory, court_order
):
    co, cnr = await court_order()
    org = await make.org()
    order = (await track(make, cnr, org))[org.id]
    [matter] = await sql("select id::text from public.matters where org_id = :o", o=org.id)
    await sql(
        "insert into public.tasks (org_id, matter_id, title, due_at, status) values "
        "(:o, :m, 'File compliance report', '2026-11-04 18:30+00', 'open'), "  # 5 Nov, not 30 Nov
        "(:o, :m, 'File compliance report', '2026-11-29 18:30+00', 'dismissed')",
        o=org.id, m=matter["id"],
    )  # fmt: skip
    await sql(
        "insert into public.deadlines (org_id, matter_id, kind, due_date, basis, status) "
        "values (:o, :m, 'filing', '2026-11-17', cast(:b as jsonb), 'active')",
        o=org.id, m=matter["id"], b=json.dumps({"title": "respondents to file  reply"}),
    )  # fmt: skip
    async with db.engine().begin() as c:
        assert await order_ai.propose(c, org.id, matter["id"], order, co, STORED_INTEL) == 3
    proposed = await sql("select title from public.tasks where org_id = :o and status = 'proposed' order by title",
                         o=org.id)  # fmt: skip
    assert [t["title"] for t in proposed] == ["Deposit costs", "File compliance report", "Petitioner to serve notice"]
    assert await sql("select id from public.deadlines where source_order_id = :o", o=order) == []


async def test_a_task_or_deadline_on_another_day_dismissed_or_deleted_hides_no_proposal(make: Factory, court_order):
    co, cnr = await court_order()
    org = await make.org()
    order = (await track(make, cnr, org))[org.id]
    [matter] = await sql("select id::text from public.matters where org_id = :o", o=org.id)
    await sql(
        "insert into public.deadlines (org_id, matter_id, kind, due_date, basis, status, deleted_at) values "
        "(:o, :m, 'filing', '2026-11-05', cast(:b as jsonb), 'active', null), "  # another day
        "(:o, :m, 'filing', '2026-11-17', cast(:b as jsonb), 'dismissed', null), "
        "(:o, :m, 'filing', '2026-11-17', cast(:b as jsonb), 'active', now())",  # deleted
        o=org.id, m=matter["id"], b=json.dumps({"title": "Respondents to file reply"}),
    )  # fmt: skip
    await sql(
        "insert into public.tasks (org_id, matter_id, title, status, deleted_at) "
        "values (:o, :m, 'Petitioner to serve notice', 'open', now())",
        o=org.id, m=matter["id"],
    )  # fmt: skip
    async with db.engine().begin() as c:
        assert await order_ai.propose(c, org.id, matter["id"], order, co, STORED_INTEL) == 4
    assert await sql("select due_date::text from public.deadlines where source_order_id = :o", o=order) == [
        {"due_date": "2026-11-17"}
    ]


async def test_an_org_reads_an_order_for_actions_once_whatever_the_language(make: Factory, court_order, model, r):
    co, cnr = await court_order()
    chamber = await make.org("Rakesh Jain", lang="hi", members={"Neha Sharma": ("junior", "en")})
    order = (await track(make, cnr, chamber))[chamber.id]
    [matter] = await sql("select matter_id::text from public.orders where id = :o", o=order)
    model(summary("Notice issued."), summary("नोटिस जारी।"), INTEL_HI)
    assert await summaries.pipeline(r, co, TODAY) == "done"  # in the owner's Hindi
    tasks = "select title, status, deleted_at is not null as deleted from public.tasks where source_ref = :o"
    hindi_task = {"title": "याचिकाकर्ता नोटिस तामील करें", "status": "proposed", "deleted": False}
    assert await sql(tasks, o=order) == [hindi_task]
    assert await sql("select id from public.notifications where org_id = :o", o=chamber.id) == []  # never new

    await sql("update public.tasks set status = 'open' where source_ref = :o", o=order)  # Confirm all
    await sql("update public.deadlines set status = 'active' where source_order_id = :o", o=order)
    junior = chamber.users["Neha Sharma"]
    job = await make.job(chamber, "order_intel", {"order_id": order, "language": "en", "credits": 2}, user=junior)
    model(INTEL)
    await jobs.run(job, summaries.order_intel_job)
    assert (await job_row(job))["result"] == {"proposed": 0}  # English titles for the same directions

    await sql("update public.tasks set status = 'dismissed', deleted_at = now() where source_ref = :o", o=order)
    await sql("update public.deadlines set status = 'dismissed', deleted_at = now() where source_order_id = :o",
              o=order)  # fmt: skip
    await sql("update public.profiles set preferred_language = 'en' where id = :u", u=chamber.owner_id)
    model()  # its English intel is stored now
    assert await summaries.pipeline(r, co, TODAY) == "done"  # a retry after the owner switched to English
    assert await sql(tasks, o=order) == [hindi_task | {"status": "dismissed", "deleted": True}]
    [n] = await sql("select count(*) as n from public.deadlines where source_order_id = :o", o=order)
    assert n["n"] == 1

    for row in (  # one row from the order, of either kind, dismissed and deleted, is enough
        "insert into public.tasks (org_id, matter_id, title, status, source, source_ref, deleted_at) "
        "select org_id, matter_id, 'Note', 'dismissed', 'order', id::text, now() from public.orders where id = :o",
        "insert into public.deadlines (org_id, matter_id, kind, due_date, status, source_order_id, deleted_at) "
        "select org_id, matter_id, 'other', '2026-11-01', 'dismissed', id, now() from public.orders where id = :o",
    ):
        await sql("delete from public.tasks where source_ref = :o", o=order)
        await sql("delete from public.deadlines where source_order_id = :o", o=order)
        await sql(row, o=order)
        async with db.engine().begin() as c:
            assert await order_ai.propose(c, chamber.id, matter["matter_id"], order, co, STORED_INTEL) == 0


async def test_a_busy_model_retries_the_task_a_failed_one_does_not(
    make: Factory, court_order, model, r, sent, monkeypatch
):
    co, cnr = await court_order(made_on=date(2026, 8, 1))
    org = await make.org()
    await track(make, cnr, org)
    model(Unavailable("ThrottlingException"))
    assert await summaries.pipeline(r, co, TODAY) == "later"
    model(CallFailed("AccessDeniedException"))
    assert await summaries.pipeline(r, co, TODAY) == "done"  # recorded, not retried
    assert await runs(org.id) == [("order_summary", "unavailable", "ai_automatic", 1),
                                  ("order_summary", "failed", "ai_automatic", 1)]  # fmt: skip

    async def later(r, court_order_id, today):
        return "later"

    monkeypatch.setattr(summaries, "pipeline", later)
    assert await asyncio.to_thread(summaries.automatic_order_ai, co) == "later"
    assert sent == [(ORDER_AI, (co,), {"attempt": 1, "countdown": 1800})]
    sent.clear()
    assert await asyncio.to_thread(summaries.automatic_order_ai, co, attempt=summaries.MAX_ATTEMPTS - 1) == "later"
    assert sent == []  # six attempts in all


# ---------------------------------------------------------------- on-demand jobs


async def job_row(job_id: str) -> dict[str, Any]:
    [row] = await sql("select status, result, error from public.jobs where id = :id", id=job_id)
    return row


async def test_an_order_summary_job_charges_credits_only_for_a_new_summary(make: Factory, court_order, model):
    _, cnr = await court_order()
    org = await make.org(members={"Rakesh Jain": ("clerk", "hi")})
    order = (await track(make, cnr, org))[org.id]
    clerk = org.users["Rakesh Jain"]
    job = await make.job(org, "order_summary", {"order_id": order, "language": "hi", "credits": 4}, user=clerk)
    model(summary("नोटिस जारी।"))
    await jobs.run(job, summaries.summarise_order_job)
    assert await job_row(job) == {"status": "done", "result": {"language": "hi"}, "error": None}
    [row] = await sql("select summary_hi->'gist'->>'text' as gist from public.orders where id = :id", id=order)
    assert row["gist"] == "नोटिस जारी।"
    assert await runs(org.id) == [("order_summary", "ok", "ai_credit", 4)]
    [run] = await sql("select user_id::text from public.ai_runs where org_id = :o", o=org.id)
    assert run["user_id"] == clerk

    again = await make.job(org, "order_summary", {"order_id": order, "language": "hi", "credits": 4})
    model()
    await jobs.run(again, summaries.summarise_order_job)
    assert (await job_row(again))["status"] == "done" and len(await runs(org.id)) == 1  # cached: free


async def test_a_job_stops_before_the_model_when_the_credits_were_spent_since(make: Factory, court_order, model):
    _, cnr = await court_order()
    org = await make.org()
    order = (await track(make, cnr, org))[org.id]
    async with db.engine().connect() as c:
        left = await ai.credits_left(c, org.id)
    await sql("insert into public.usage_ledger (org_id, kind, quantity) values (:o, 'ai_credit', :q)",
              o=org.id, q=left - 3)  # fmt: skip  # another request's job, accepted with this one
    job = await make.job(org, "order_summary", {"order_id": order, "language": "en", "credits": 4})
    model()  # never called
    await jobs.run(job, summaries.summarise_order_job)
    assert await job_row(job) == {"status": "failed", "result": None, "error": "AI_CREDITS_EXHAUSTED"}
    assert await runs(org.id) == []


async def test_jobs_wait_for_text_and_fail_on_unreadable_text_or_a_failed_model(make: Factory, court_order, model):
    org = await make.org()
    _, cnr = await court_order(status="ocr_pending", pages={})
    _, cnr2 = await court_order(status="text", pages={})  # read, but blank
    _, cnr3 = await court_order()
    orders = [(await track(make, c, org))[org.id] for c in (cnr, cnr2, cnr3)]
    inputs = [{"order_id": o, "language": "en", "credits": 4} for o in orders]

    with pytest.raises(jobs.RetryLater, match="ORDER_TEXT_PENDING"):
        await jobs.run(await make.job(org, "order_summary", inputs[0]), summaries.summarise_order_job)
    failed = await make.job(org, "order_summary", inputs[1])
    await jobs.run(failed, summaries.summarise_order_job)
    assert (await job_row(failed))["error"] == "ORDER_TEXT_UNREADABLE"

    model(Unavailable("ThrottlingException"))
    with pytest.raises(jobs.RetryLater, match="AI_BUSY"):
        await jobs.run(await make.job(org, "order_summary", inputs[2]), summaries.summarise_order_job)
    model("not json", "still not", "nope")
    broken = await make.job(org, "order_summary", inputs[2])
    await jobs.run(broken, summaries.summarise_order_job)
    assert (await job_row(broken))["error"] == "AI_FAILED"
    never_charged = [("order_summary", "unavailable", None, None), ("order_summary", "invalid_output", None, None)]
    assert await runs(org.id) == never_charged  # but recorded


async def test_an_uploaded_orders_summary_is_the_orgs_own(make: Factory, model):
    org = await make.org(members={"Rakesh Jain": ("junior", "en")})
    matter = await make.matter(org, make.cnr())
    [doc] = await sql(
        "insert into public.documents (org_id, matter_id, title, kind, upload_status, text_status, pages) "
        "values (:o, :m, 'Order 20.10.2026', 'order', 'ready', 'text', 2) returning id::text",
        o=org.id, m=matter,
    )  # fmt: skip
    await sql(
        "insert into public.document_chunks (org_id, document_id, page_no, chunk_no, text) values "
        "(:o, :d, 1, 0, 'Heard.'), (:o, :d, 2, 0, 'Reply in four weeks.')",
        o=org.id, d=doc["id"],
    )  # fmt: skip
    user = org.users["Rakesh Jain"]
    job = await make.job(org, "document_summary", {"document_id": doc["id"], "language": "en", "credits": 4}, user=user)
    model(summary("Reply in four weeks."))
    await jobs.run(job, summaries.summarise_document_job)
    assert (await job_row(job))["result"] == {"language": "en"}
    [answer] = await sql(
        "select matter_id::text, kind, answer, sources, created_by::text, run_id is not null as run "
        "from public.ai_answers where document_id = :d", d=doc["id"]
    )  # fmt: skip
    assert answer["answer"]["source_pages"] == {"S1": 1, "S2": 2}
    assert {k: answer[k] for k in ("matter_id", "kind", "sources", "created_by", "run")} == {
        "matter_id": matter, "kind": "upload_summary", "sources": [{"id": "S1", "page": 1}, {"id": "S2", "page": 2}],
        "created_by": user, "run": True,
    }  # fmt: skip
    assert await runs(org.id) == [("order_summary", "ok", "ai_credit", 4)]

    again = await make.job(org, "document_summary", {"document_id": doc["id"], "language": "en", "credits": 4})
    model()
    await jobs.run(again, summaries.summarise_document_job)
    assert (await job_row(again))["status"] == "done" and len(await runs(org.id)) == 1  # stored: free


async def test_an_order_intel_job_proposes_for_its_org(make: Factory, court_order, model):
    _, cnr = await court_order()
    org = await make.org()
    order = (await track(make, cnr, org))[org.id]
    job = await make.job(org, "order_intel", {"order_id": order, "language": "en", "credits": 2})
    model(INTEL)
    await jobs.run(job, summaries.order_intel_job)
    assert (await job_row(job))["result"] == {"proposed": 4}
    assert await runs(org.id) == [("order_intel", "ok", "ai_credit", 2)]

    _, undated = await court_order(made_on=None)
    undated_order = (await track(make, undated, org))[org.id]
    job = await make.job(org, "order_intel", {"order_id": undated_order, "language": "en", "credits": 2})
    await jobs.run(job, summaries.order_intel_job)
    assert (await job_row(job))["error"] == "ORDER_DATE_UNKNOWN"
