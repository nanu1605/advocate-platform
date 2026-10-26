"""Search inside documents (spec §12.4, F06, F15): the organisation's uploads and the court orders it tracks, scans
included, as the user (row-level security), full text alone or hybrid with the embedder's fake models."""

import httpx
import pytest

from advocate_embedder.app import create_app
from advocate_embedder.fake import FakeModels
from advocate_shared import embedder

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


async def test_hybrid_ranks_with_the_embedder(api, team, files, monkeypatch):
    client = embedder.Embedder("http://embedder", transport=httpx.ASGITransport(app=create_app(FakeModels())))
    monkeypatch.setattr(embedder, "configured", lambda: client)
    r = await search(api, team, query="bail granted on a bond")
    hits = r.json()["hits"]
    assert hits[0]["document_id"] == files["bail"] and hits[0]["page"] == 2
    assert files["other"] not in {h["document_id"] for h in hits}

    async def down(self, *args):
        raise httpx.ConnectError("down")

    monkeypatch.setattr(embedder.Embedder, "embed", down)
    monkeypatch.setattr(embedder.Embedder, "rerank", down)
    r = await search(api, team, query="bail granted on a bond")  # the full text still answers
    assert r.status_code == 200 and r.json()["hits"][0]["document_id"] == files["bail"]


async def test_needs_membership_and_a_query(api, team, files):
    r = await search(api, team, "outsider", query="जमानत")
    assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_A_MEMBER"
    assert (await search(api, team, query="j")).status_code == 422
    assert (await search(api, team, query="x" * 201)).status_code == 422


async def test_rate_limited(api, team, files, monkeypatch):
    monkeypatch.setattr(embedder, "configured", lambda: None)
    for _ in range(30):
        await search(api, team, "clerk", query="nothing here")
    r = await search(api, team, "clerk", query="nothing here")
    assert r.status_code == 429 and r.json()["error"]["code"] == "RATE_LIMITED"
