"""Search inside documents (spec §12.4, F06, F15): the organisation's uploads and the court orders it tracks, scans
included, as the user (row-level security), full text alone or hybrid with the embedder's fake models."""

import asyncio

import httpx
import pytest

from advocate_api.ratelimit import redis
from advocate_embedder.app import create_app
from advocate_embedder.fake import FakeModels
from advocate_shared import embedder, retrieval

from .conftest import make_team, sql

PHONES = {
    "owner": ("919999900041", "owner"),
    "clerk": ("919999900042", "clerk"),
    "outsider": ("919999900043", None),
}
OTHER = {"other": ("919999900044", "owner")}
CNR = "TEST0400000412026"
BAIL = "आवेदक को ज़मानत पर रिहा किया जाए। Bail granted on a bond of Rs. 25,000."


@pytest.fixture(scope="module")
async def team():
    return await make_team(PHONES)


@pytest.fixture(scope="module")
async def other():
    return await make_team(OTHER)


async def matter(org_id: str, title: str, cnr: str | None = None) -> str:
    [row] = await sql(
        "insert into public.matters (org_id, source, tracking, cnr, case_type, case_number, case_year, title, stage) "
        "values (:o, 'manual', 'manual', :c, 'WP', '1', 2024, :t, 'Admission') returning id::text",
        o=org_id, c=cnr, t=title,
    )  # fmt: skip
    return row["id"]


async def document(org_id: str, matter_id: str | None, title: str, pages: list[str], **cols: object) -> str:
    [row] = await sql(
        "insert into public.documents (org_id, matter_id, title, upload_status, deleted_at) "
        "values (:o, :m, :t, :s, case when :d then now() end) returning id::text",
        o=org_id, m=matter_id, t=title, s=cols.get("status", "ready"), d=cols.get("deleted", False),
    )  # fmt: skip
    for page_no, text in enumerate(pages, 1):
        [v] = FakeModels().embed([text])
        await sql(
            "insert into public.document_chunks (org_id, document_id, page_no, chunk_no, paras, text, embedding) "
            "values (:o, :d, :p, 0, '{4}', :t, cast(:v as extensions.vector))",
            o=org_id, d=row["id"], p=page_no, t=text, v=embedder.vector(v),
        )  # fmt: skip
    return row["id"]


@pytest.fixture(scope="module")
async def files(team, other):
    """Two cases in the team's organisation, a court order on one, and other files the search must never return."""
    await sql("delete from public.court_orders where cnr = :c", c=CNR)
    await sql("delete from public.court_cases where cnr = :c", c=CNR)
    await sql(
        "insert into public.court_cases (cnr, court_id, title) values (:c, :court, 'x')",
        c=CNR,
        court="c0000000-0000-0000-0000-000000000003",
    )
    wp = await matter(team.org_id, "Sharma v. State", CNR)
    cra = await matter(team.org_id, "Lal v. State")
    found = {
        "bail": await document(team.org_id, wp, "Bail order", ["Cover page of the order.", BAIL]),
        "reply": await document(team.org_id, cra, "Reply", ["The respondent shall file a reply within four weeks."]),
        "deleted": await document(team.org_id, wp, "Old bail order", [BAIL], deleted=True),
        "pending": await document(team.org_id, wp, "Unscanned bail order", [BAIL], status="pending"),
        "other": await document(other.org_id, None, "Their bail order", [BAIL]),
    }
    [co] = await sql(
        "insert into public.court_orders (cnr, provider_ref) values (:c, 'o-search') returning id::text", c=CNR
    )
    [order] = await sql(
        "insert into public.orders (org_id, matter_id, court_order_id, title) values (:o, :m, :c, 'Order 20-10-2026') "
        "returning id::text",
        o=team.org_id, m=wp, c=co["id"],
    )  # fmt: skip
    await sql(
        "insert into public.document_chunks (court_order_id, page_no, chunk_no, text) "
        "values (:c, 3, 0, 'Interim protection: no coercive action till the next date. जमानत पर विचार होगा।')",
        c=co["id"],
    )
    yield found | {"order": order["id"], "wp": wp, "cra": cra}
    await sql("delete from public.court_orders where cnr = :c", c=CNR)
    await sql("delete from public.court_cases where cnr = :c", c=CNR)


async def search(api, team, who: str = "owner", **body):
    return await api.post("/v1/documents/search", json=body, headers=team.h(who))


async def test_full_text_finds_words_however_written(api, team, files, monkeypatch):
    monkeypatch.setattr(embedder, "configured", lambda: None)
    r = await search(api, team, query="जमानत")  # no nukta; the bail order has ज़मानत
    assert r.status_code == 200, r.text
    hits = r.json()["hits"]
    assert {(h["document_id"], h["order_id"]) for h in hits} == {(files["bail"], None), (None, files["order"])}
    bail = next(h for h in hits if h["document_id"] == files["bail"])
    assert bail | {"snippet": None} == {
        "document_id": files["bail"],
        "order_id": None,
        "matter_id": files["wp"],
        "title": "Bail order",
        "page": 2,
        "paras": ["4"],
        "snippet": None,
    }
    assert "ज़मानत" in bail["snippet"]
    order = next(h for h in hits if h["order_id"] == files["order"])
    assert (order["matter_id"], order["title"], order["page"]) == (files["wp"], "Order 20-10-2026", 3)


async def test_narrows_to_one_case_and_any_member_can_search(api, team, files, monkeypatch):
    monkeypatch.setattr(embedder, "configured", lambda: None)
    r = await search(api, team, "clerk", query="reply four weeks", matter_id=files["cra"])
    assert [h["document_id"] for h in r.json()["hits"]] == [files["reply"]]
    r = await search(api, team, query="reply four weeks", matter_id=files["wp"])
    assert r.json()["hits"] == []


async def test_full_text_puts_pages_with_every_word_first(api, team, files, monkeypatch):
    monkeypatch.setattr(embedder, "configured", lambda: None)
    case = await matter(team.org_id, "Verma v. State")
    filler = await document(team.org_id, case, "Order sheet", ["अर्जी पर सुनवाई हुई। " * 25])
    plea = await document(team.org_id, case, "Adjournment", ["वादी की ओर से स्थगन की अर्जी प्रस्तुत की गई।"])
    r = await search(api, team, query="स्थगन की अर्जी", matter_id=case)  # not the page full of अर्जी
    assert [h["document_id"] for h in r.json()["hits"]] == [plea, filler]


async def test_full_text_leaves_out_common_words(api, team, files, monkeypatch):
    monkeypatch.setattr(embedder, "configured", lambda: None)
    await document(team.org_id, files["wp"], "Evidence", ["वादी की ओर से साक्षी की गवाही। " * 25])
    r = await search(api, team, query="सुरेश की जमानत", matter_id=files["wp"])  # no page has every word
    hits = {(h["document_id"], h["order_id"]) for h in r.json()["hits"]}
    assert hits == {(files["bail"], None), (None, files["order"])}  # not the page full of की
    r = await search(api, team, query="की", matter_id=files["wp"])  # only common words: as they are
    assert [h["title"] for h in r.json()["hits"]] == ["Evidence"]


async def test_hybrid_ranks_with_the_embedder(api, team, files, monkeypatch):
    client = embedder.Embedder("http://embedder", transport=httpx.ASGITransport(app=create_app(FakeModels())))
    monkeypatch.setattr(embedder, "configured", lambda: client)
    r = await search(api, team, query="bail granted on a bond")
    hits = r.json()["hits"]
    assert hits[0]["document_id"] == files["bail"] and hits[0]["page"] == 2
    assert files["other"] not in {h["document_id"] for h in hits}

    embed = embedder.Embedder.embed

    async def down(self, *args):
        raise httpx.ConnectError("down")

    monkeypatch.setattr(embedder.Embedder, "embed", down)
    monkeypatch.setattr(embedder.Embedder, "rerank", down)
    r = await search(api, team, query="bail granted on a bond")  # the full text still answers
    assert r.status_code == 200 and r.json()["hits"][0]["document_id"] == files["bail"]

    async def slow(self, *args):
        await asyncio.sleep(5)

    monkeypatch.setattr(retrieval, "WAIT_S", 0.5)
    monkeypatch.setattr(embedder.Embedder, "embed", embed)
    for patched in ("rerank", "embed"):  # a slow reranker, then a slow embedder, is not waited for
        monkeypatch.setattr(embedder.Embedder, patched, slow)
        r = await search(api, team, query="bail granted on a bond")
        assert r.status_code == 200 and r.json()["hits"][0]["document_id"] == files["bail"], patched


async def test_pages_found_by_meaning_alone_need_the_reranker(api, team, files, monkeypatch):
    client = embedder.Embedder("http://embedder", transport=httpx.ASGITransport(app=create_app(FakeModels())))
    monkeypatch.setattr(embedder, "configured", lambda: client)
    r = await search(api, team, query="release surety")  # words in no page: the nearest pages are not hits
    assert r.status_code == 200 and r.json()["hits"] == []

    async def bail_is_near(self, query, passages):  # as the real reranker scores the bail order for these words
        return [0.6 if "Bail" in p else 0.0 for p in passages]

    monkeypatch.setattr(embedder.Embedder, "rerank", bail_is_near)
    r = await search(api, team, query="release surety")
    assert [(h["document_id"], h["page"]) for h in r.json()["hits"]] == [(files["bail"], 2)]

    async def down(self, *args):
        raise httpx.ConnectError("down")

    monkeypatch.setattr(embedder.Embedder, "rerank", down)
    assert (await search(api, team, query="release surety")).json()["hits"] == []

    def late(call):
        async def after(*args):
            await asyncio.sleep(0.3)
            return await call(*args)

        return after

    monkeypatch.setattr(retrieval, "WAIT_S", 0.5)
    monkeypatch.setattr(embedder.Embedder, "embed", late(embedder.Embedder.embed))
    monkeypatch.setattr(embedder.Embedder, "rerank", late(bail_is_near))
    r = await search(api, team, query="release surety")  # each wait is under WAIT_S, but both share it
    assert r.status_code == 200 and r.json()["hits"] == []


async def test_needs_membership_and_a_query(api, team, files):
    r = await search(api, team, "outsider", query="जमानत")
    assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_A_MEMBER"
    assert (await search(api, team, query="j")).status_code == 422
    assert (await search(api, team, query="x" * 201)).status_code == 422


async def test_rate_limited(api, team, files):
    counter = f"rl:doc-search:{team.users['clerk']}"
    await redis().set(counter, 30, ex=60)  # this minute's 30 searches used
    try:
        r = await search(api, team, "clerk", query="nothing here")
    finally:
        await redis().delete(counter)  # the other tests search as the clerk too
    assert r.status_code == 429 and r.json()["error"]["code"] == "RATE_LIMITED"
