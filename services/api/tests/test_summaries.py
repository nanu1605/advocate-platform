"""On-demand order summaries and order intelligence (spec §10.2, F07, F13, §14.2, ADR 0023) against the local stack:
stored outputs answered free, else a job once the user agreed to its price in credits."""

import json
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from datetime import date
from typing import Any

import pytest

from advocate_api import storage
from advocate_api.db import service_db
from advocate_api.ratelimit import redis
from advocate_shared import ai, order_ai
from advocate_shared.tasks import EXTRACT_TEXT, ORDER_INTEL, SUMMARISE_DOCUMENT, SUMMARISE_ORDER
from legal_ai.prompts import load_prompt

from .conftest import make_team, sql

PHONES = {"owner": ("919999900026", "owner"), "junior": ("919999900036", "junior"), "clerk": ("919999900039", "clerk")}
OTHER = {"outsider": ("919999900040", "owner")}
CNR = "TEST050000052024"  # the synthetic provider has its order-2.pdf
STORED = "test/not-fetched.pdf"
SUMMARY = {"gist": "Reply within four weeks.", "source_pages": {"S1": 1}}
config = ai.configured_llm().config

type MakeOrder = Callable[..., Awaitable[tuple[str, str]]]


@pytest.fixture(scope="module")
async def team():
    return await make_team(PHONES)


@pytest.fixture(scope="module")
async def other():
    return await make_team(OTHER)


@pytest.fixture(scope="module")
async def matter_id(team) -> str:
    [row] = await sql(
        "insert into public.matters (org_id, cnr, source, tracking) values (:o, :c, 'cnr', 'manual') "
        "returning id::text",
        o=team.org_id, c=CNR,
    )  # fmt: skip
    return row["id"]


@pytest.fixture(autouse=True)
async def fresh_limit(team):
    await redis().delete(*(f"rl:ai:{u}" for u in team.users.values()))


@pytest.fixture
async def make_order(team, matter_id) -> AsyncIterator[MakeOrder]:
    """The team's order on a new court order, its text read (7 pages, one chunk) unless told otherwise. Removed
    afterwards with its shared outputs and any PDF fetched for it (the orders row stays, court_order_id null)."""
    made: list[str] = []

    async def make(
        *, ref: str | None = None, storage_path: str | None = STORED, text_status: str = "text", chunks: bool = True,
        order_date: date | None = None,
    ) -> tuple[str, str]:  # fmt: skip
        [co] = await sql(
            "insert into public.court_orders (cnr, provider_ref, storage_path, text_status, pages, order_date) "
            "values (:c, :r, :p, :s, 7, :d) on conflict (cnr, provider_ref) do update set "
            "storage_path = excluded.storage_path, text_status = excluded.text_status, pages = 7, "
            "order_date = excluded.order_date "
            "returning id::text",
            c=CNR, r=ref or f"o-{uuid.uuid4().hex[:8]}", p=storage_path, s=text_status, d=order_date,
        )  # fmt: skip  # a crashed earlier run may have left order-2.pdf's row
        made.append(co["id"])
        if chunks:
            await sql(
                "insert into public.document_chunks (court_order_id, page_no, chunk_no, text) "
                "values (:c, 1, 0, 'The respondent shall file a reply within four weeks.')",
                c=co["id"],
            )
        [order] = await sql(
            "insert into public.orders (org_id, matter_id, court_order_id, title) values (:o, :m, :c, 'Order') "
            "returning id::text",
            o=team.org_id, m=matter_id, c=co["id"],
        )  # fmt: skip
        return order["id"], co["id"]

    yield make
    for co in made:
        await sql("delete from public.public_summaries where doc_ref = :c", c=co)
        [row] = await sql("delete from public.court_orders where id = :c returning storage_path", c=co)
        if row["storage_path"] not in (None, STORED):
            r = await storage._call("DELETE", "/object/court-orders", json={"prefixes": [row["storage_path"]]})
            r.raise_for_status()


def key() -> dict[str, str]:
    return {"Idempotency-Key": f"key-{uuid.uuid4()}"}


async def store(doc: order_ai.Doc, court_order_id: str, language: str, output: dict[str, Any]) -> None:
    """A shared output as the workers store it, made with the current prompt."""
    await sql(
        "insert into public.public_summaries (doc_kind, doc_ref, language, summary, model_id, prompt_version) "
        "values (:k, :r, :l, cast(:s as jsonb), 'test', :v)",
        k=doc, r=court_order_id, l=language, s=json.dumps(output), v=load_prompt(order_ai.TASKS[doc]).version,
    )  # fmt: skip


async def left(org_id: str) -> int:
    async with service_db() as c:
        return await ai.credits_left(c, org_id)


async def job(job_id: str) -> dict[str, Any]:
    [row] = await sql(
        "select kind, input, org_id::text, user_id::text, status from public.jobs where id = :id", id=job_id
    )
    return row


def error(r) -> dict[str, Any]:
    return r.json()["error"]


async def test_stored_order_summary_is_free(api, team, make_order, enqueued):
    order, co = await make_order()
    await sql("update public.orders set summary_hi = cast(:s as jsonb) where id = :id", s=json.dumps(SUMMARY), id=order)
    r = await api.post(f"/v1/orders/{order}/summary", headers=team.h("clerk", **key()), json={"language": "hi"})
    assert r.status_code == 200, r.text
    assert r.json() == {"status": "ready", "summary": SUMMARY}

    english = SUMMARY | {"gist": "Reply in four weeks."}
    await store("court_order", co, "en", english)  # not on the orders row yet
    r = await api.post(f"/v1/orders/{order}/summary", headers=team.h("clerk", **key()), json={"language": "en"})
    assert r.status_code == 200 and r.json() == {"status": "ready", "summary": english}
    assert await sql("select summary_en from public.orders where id = :id", id=order) == [{"summary_en": english}]
    assert enqueued == []
    assert await sql("select id from public.jobs where org_id = :o and kind = 'order_summary'", o=team.org_id) == []


async def test_order_summary_job_after_the_price_is_agreed(api, team, make_order, enqueued):
    order, co = await make_order()
    await store("court_order", co, "hi", SUMMARY)  # the other language is no help
    price = config.credits_for("order_summary", 7)
    url = f"/v1/orders/{order}/summary"
    r = await api.post(url, headers=team.h("clerk", **key()), json={"language": "en", "credits": price - 1})
    assert r.status_code == 409 and error(r) == {
        "code": "AI_CREDITS_NEEDED",
        "message": "This uses AI credits",
        "retryable": False,
        "details": {"credits": price, "left": await left(team.org_id)},
    }
    assert enqueued == []

    h = team.h("clerk", **key())
    r = await api.post(url, headers=h, json={"language": "en", "credits": price + 10})
    assert r.status_code == 202, r.text
    assert r.json() == {"status": "queued", "job_id": r.json()["job_id"]}
    job_id = r.json()["job_id"]
    assert await job(job_id) == {
        "kind": "order_summary",
        "input": {"order_id": order, "language": "en", "credits": price},  # charged the price, not the offer
        "org_id": team.org_id,
        "user_id": team.users["clerk"],
        "status": "queued",
    }
    assert enqueued == [(SUMMARISE_ORDER, job_id)]

    again = await api.post(url, headers=h, json={"language": "en", "credits": price + 10})
    assert again.status_code == 202 and again.json() == r.json()
    assert again.headers["Idempotent-Replay"] == "true"
    assert enqueued == [(SUMMARISE_ORDER, job_id)]


async def test_credits_exhausted(api, team, make_order, enqueued):
    order, _ = await make_order()
    price = config.credits_for("order_summary", 7)
    [spent] = await sql(
        "insert into public.usage_ledger (org_id, kind, quantity) values (:o, 'ai_credit', :q) returning id",
        o=team.org_id, q=await left(team.org_id) - price + 1,
    )  # fmt: skip
    try:
        for credits in (0, price):  # not worth asking about
            r = await api.post(
                f"/v1/orders/{order}/summary",
                headers=team.h("owner", **key()),
                json={"language": "hi", "credits": credits},
            )
            assert r.status_code == 402 and error(r)["code"] == "AI_CREDITS_EXHAUSTED"
            assert error(r)["details"] == {"credits": price, "left": price - 1}
    finally:
        await sql("delete from public.usage_ledger where id = :id", id=spent["id"])
    assert enqueued == []


async def test_text_pending_fetches_the_pdf(api, team, make_order, enqueued):
    order, co = await make_order(ref="order-2.pdf", storage_path=None, text_status="none", chunks=False)
    url, body = f"/v1/orders/{order}/summary", {"language": "hi", "credits": 24}
    calls = "select count(*) as n from public.provider_calls where org_id = :o and operation = 'order_pdf'"

    lock = f"order-pdf:{co}"
    await redis().set(lock, "1", ex=60)  # another request is fetching it
    try:
        r = await api.post(url, headers=team.h("owner", **key()), json=body)
    finally:
        await redis().delete(lock)
    assert r.status_code == 409 and error(r) == {
        "code": "ORDER_TEXT_PENDING",
        "message": "This order is still being read",
        "retryable": True,
        "details": {},
    }
    assert enqueued == []

    r = await api.post(url, headers=team.h("owner", **key()), json=body)
    assert r.status_code == 409 and error(r)["code"] == "ORDER_TEXT_PENDING"
    [stored] = await sql("select storage_path from public.court_orders where id = :id", id=co)
    assert stored["storage_path"].startswith(f"{CNR}/")
    assert enqueued == [(EXTRACT_TEXT, "court_order", co)]  # its text is read next
    assert await sql(calls, o=team.org_id) == [{"n": 1}]

    await sql("update public.court_orders set text_status = 'ocr_pending' where id = :id", id=co)
    intel = {"order_id": order, "credits": 24}
    for r in (
        await api.post(url, headers=team.h("owner", **key()), json=body),
        await api.post("/v1/ai/order-intel", headers=team.h("owner", **key()), json=intel),
    ):
        assert r.status_code == 409 and error(r)["code"] == "ORDER_TEXT_PENDING"
    assert enqueued == [(EXTRACT_TEXT, "court_order", co)]  # fetched once
    assert await sql(calls, o=team.org_id) == [{"n": 1}]


@pytest.mark.parametrize(
    "text", [{"text_status": "failed", "chunks": False}, {"chunks": False}], ids=["failed", "blank"]
)
async def test_text_unreadable(api, team, make_order, enqueued, text):
    order, _ = await make_order(order_date=date(2026, 10, 20), **text)
    for url, body in (
        (f"/v1/orders/{order}/summary", {"language": "hi", "credits": 24}),
        ("/v1/ai/order-intel", {"order_id": order, "credits": 24}),
    ):
        r = await api.post(url, headers=team.h("owner", **key()), json=body)
        assert r.status_code == 409 and error(r)["code"] == "ORDER_TEXT_UNREADABLE", r.text
    assert enqueued == []


async def test_order_lookup(api, team, other, matter_id, make_order):
    order, _ = await make_order()
    [typed] = await sql(
        "insert into public.orders (org_id, matter_id, title) values (:o, :m, 'Typed order') returning id::text",
        o=team.org_id, m=matter_id,
    )  # fmt: skip
    [gone] = await sql(
        "insert into public.orders (org_id, matter_id, title, deleted_at) values (:o, :m, 'Gone', now()) "
        "returning id::text",
        o=team.org_id, m=matter_id,
    )  # fmt: skip

    async def both(order_id: str, headers: dict[str, str]) -> list[tuple[int, str]]:
        summary = await api.post(f"/v1/orders/{order_id}/summary", headers=headers | key(), json={"language": "hi"})
        intel = await api.post("/v1/ai/order-intel", headers=headers | key(), json={"order_id": order_id})
        return [(r.status_code, error(r)["code"]) for r in (summary, intel)]

    assert await both(typed["id"], team.h("junior")) == [(409, "ORDER_SUMMARY_UNAVAILABLE")] * 2
    assert await both(gone["id"], team.h("junior")) == [(404, "NOT_FOUND")] * 2
    assert await both(str(uuid.uuid4()), team.h("junior")) == [(404, "NOT_FOUND")] * 2
    assert await both(order, other.h("outsider")) == [(404, "NOT_FOUND")] * 2  # another organisation's
    outsider = {"Authorization": f"Bearer {other.tokens['outsider']}", "X-Org-Id": team.org_id}
    assert await both(order, outsider) == [(403, "NOT_A_MEMBER")] * 2


async def test_document_summary(api, team, other, matter_id, enqueued):
    async def document(**cols: Any) -> str:
        [row] = await sql(
            "insert into public.documents (org_id, matter_id, title, kind, mime, upload_status, text_status) "
            "values (:o, :m, 'Order', :k, :mime, :u, :t) returning id::text",
            o=team.org_id, m=matter_id, k=cols.get("kind", "order"), u=cols.get("upload", "ready"),
            t=cols.get("text", "text"), mime="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        )  # fmt: skip
        for chunk_no in range(cols.get("chunks", 6)):  # a DOCX: one page, its chunks stand in for the count
            await sql(
                "insert into public.document_chunks (org_id, document_id, page_no, chunk_no, text) "
                "values (:o, :d, 1, :n, 'Reply within four weeks.')",
                o=team.org_id, d=row["id"], n=chunk_no,
            )  # fmt: skip
        return row["id"]

    async def post(doc: str, who: str = "clerk", **body: object) -> Any:
        return await api.post(
            f"/v1/documents/{doc}/summary", headers=team.h(who, **key()), json={"language": "hi"} | body
        )

    doc, price = await document(), config.credits_for("order_summary", 6)
    r = await post(doc)
    assert r.status_code == 409 and error(r)["code"] == "AI_CREDITS_NEEDED"
    assert error(r)["details"] == {"credits": price, "left": await left(team.org_id)}
    r = await post(doc, credits=price)
    assert r.status_code == 202, r.text
    assert await job(r.json()["job_id"]) == {
        "kind": "document_summary",
        "input": {"document_id": doc, "language": "hi", "credits": price},
        "org_id": team.org_id,
        "user_id": team.users["clerk"],
        "status": "queued",
    }
    assert enqueued == [(SUMMARISE_DOCUMENT, r.json()["job_id"])]

    await sql(
        "insert into public.ai_answers (org_id, matter_id, document_id, kind, language, answer) "
        "values (:o, :m, :d, 'upload_summary', 'hi', cast(:a as jsonb))",
        o=team.org_id, m=matter_id, d=doc, a=json.dumps(SUMMARY),
    )  # fmt: skip
    r = await post(doc)
    assert r.status_code == 200 and r.json() == {"status": "ready", "summary": SUMMARY}

    codes = {
        "pleading": await post(await document(kind="pleading")),
        "unscanned": await post(await document(upload="pending")),
        "quarantined": await post(await document(upload="quarantined")),
        "unread": await post(await document(text="none", chunks=0), credits=24),
        "blank": await post(await document(chunks=0), credits=24),
        "other org": await api.post(
            f"/v1/documents/{doc}/summary", headers=other.h("outsider", **key()), json={"language": "hi"}
        ),
        "missing": await post(str(uuid.uuid4())),
    }
    assert {k: (r.status_code, error(r)["code"]) for k, r in codes.items()} == {
        "pleading": (409, "DOCUMENT_NOT_AN_ORDER"),
        "unscanned": (409, "DOCUMENT_NOT_READY"),
        "quarantined": (409, "DOCUMENT_QUARANTINED"),
        "unread": (409, "ORDER_TEXT_PENDING"),  # an upload's text follows its scan: nothing to fetch
        "blank": (409, "ORDER_TEXT_UNREADABLE"),
        "other org": (404, "NOT_FOUND"),
        "missing": (404, "NOT_FOUND"),
    }
    assert len(enqueued) == 1


async def test_order_intel(api, team, make_order, enqueued):
    async def language(who: str, lang: str) -> None:
        await sql("update public.profiles set preferred_language = :l where id = :u", l=lang, u=team.users[who])

    order, co = await make_order()
    url = "/v1/ai/order-intel"
    body = {"order_id": order}  # read in the owner's language (Hindi), whoever asks
    r = await api.post(url, headers=team.h("clerk", **key()), json=body)
    assert r.status_code == 403 and error(r)["code"] == "ROLE_NOT_ALLOWED"
    assert error(r)["details"] == {"roles": ["owner", "advocate", "junior"]}

    r = await api.post(url, headers=team.h("junior", **key()), json=body | {"credits": 24})
    assert r.status_code == 409 and error(r)["code"] == "ORDER_DATE_UNKNOWN"  # no date from the court or a summary
    await store("court_order", co, "en", SUMMARY | {"order_date": "2026-10-20"})
    await store("order_intel", co, "en", {"actions": [], "order_date": "2026-10-20"})  # another org's: no help

    price = config.credits_for("order_intel")
    await language("junior", "en")  # an English junior still gets the Hindi owner's reading
    try:
        r = await api.post(url, headers=team.h("junior", **key()), json=body)
        assert r.status_code == 409 and error(r)["code"] == "AI_CREDITS_NEEDED"
        assert error(r)["details"] == {"credits": price, "left": await left(team.org_id)}
        r = await api.post(url, headers=team.h("junior", **key()), json=body | {"credits": price})
        assert r.status_code == 202, r.text
    finally:
        await language("junior", "hi")
    assert await job(r.json()["job_id"]) == {
        "kind": "order_intel",
        "input": {"order_id": order, "language": "hi", "credits": price},
        "org_id": team.org_id,
        "user_id": team.users["junior"],
        "status": "queued",
    }
    assert enqueued == [(ORDER_INTEL, r.json()["job_id"])]

    await language("owner", "en")  # and once the owner reads English, the stored English reading is theirs, free
    try:
        r = await api.post(url, headers=team.h("junior", **key()), json=body)
        assert r.status_code == 200 and r.json() == {"status": "ready", "proposed": 0}
    finally:
        await language("owner", "hi")
    assert len(enqueued) == 1

    intel = {
        "actions": [
            {"kind": "task", "title": "File the reply", "due": None, "sources": ["S1"]},
            {"kind": "deadline", "title": "Deposit costs", "due": {"within": 2, "unit": "weeks"}, "sources": ["S1"]},
        ],
        "order_date": "2026-10-20",
        "source_pages": {"S1": 1},
    }
    await store("order_intel", co, "hi", intel)
    r = await api.post(url, headers=team.h("owner", **key()), json=body)
    assert r.status_code == 200 and r.json() == {"status": "ready", "proposed": 2}
    tasks = await sql(
        "select title, status, source, source_ref, created_by from public.tasks where source_ref = :o", o=order
    )
    assert tasks == [
        {"title": "File the reply", "status": "proposed", "source": "order", "source_ref": order, "created_by": None}
    ]
    [deadline] = await sql(
        "select due_date::text, status, basis from public.deadlines where source_order_id = :o", o=order
    )
    assert deadline["due_date"] == "2026-11-03" and deadline["status"] == "proposed"
    assert deadline["basis"]["verify"] is True and deadline["basis"]["pages"] == [1]

    r = await api.post(url, headers=team.h("owner", **key()), json=body)
    assert r.status_code == 200 and r.json() == {"status": "ready", "proposed": 0}  # never twice
    assert len(enqueued) == 1

    await sql("update public.tasks set status = 'dismissed', deleted_at = now() where source_ref = :o", o=order)
    await sql("update public.deadlines set status = 'active' where source_order_id = :o", o=order)
    await sql("delete from public.public_summaries where doc_kind = 'order_intel' and doc_ref = :c", c=co)  # new prompt
    r = await api.post(url, headers=team.h("junior", **key()), json=body)
    assert r.status_code == 200 and r.json() == {"status": "ready", "proposed": 0}  # read before: nothing to pay for
    assert len(enqueued) == 1


async def test_rate_limit(api, team, make_order):
    order, _ = await make_order()
    counter = f"rl:ai:{team.users['owner']}"
    await redis().set(counter, 29, ex=60)  # 29 of this minute's 30 used
    last = await api.post(f"/v1/orders/{order}/summary", headers=team.h("owner", **key()), json={"language": "hi"})
    over = await api.post(f"/v1/orders/{order}/summary", headers=team.h("owner", **key()), json={"language": "hi"})
    assert last.status_code == 409  # AI_CREDITS_NEEDED: through the limit
    assert over.status_code == 429 and error(over)["code"] == "RATE_LIMITED"
    assert error(over)["details"]["retry_after_s"] >= 1


@pytest.mark.parametrize(
    ("headers", "body"),
    [
        ({}, {"language": "hi"}),  # no Idempotency-Key
        (key(), {"language": "fr"}),
        (key(), {"language": "hi", "credits": -1}),
        (key(), {}),
    ],
)
async def test_validation(api, team, make_order, headers, body):
    order, _ = await make_order()
    r = await api.post(f"/v1/orders/{order}/summary", headers=team.h("owner", **headers), json=body)
    assert r.status_code == 422 and error(r)["code"] == "VALIDATION_ERROR"
