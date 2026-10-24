"""Tomorrow's Board and feedback (spec §4.2, §10.2)."""

from datetime import timedelta

import pytest

from advocate_api.routes.board import natural
from advocate_shared.ist import today_ist

from .conftest import auth, make_team, sql

PHONES = {
    "owner": ("919999900028", "owner"),
    "clerk": ("919999900029", "clerk"),
    "outsider": ("919999900030", None),
    "writer": ("919999900031", "advocate"),
}
JABALPUR, INDORE_HC, INDORE_DC = (f"c0000000-0000-0000-0000-00000000000{n}" for n in (2, 3, 5))


@pytest.fixture(scope="module")
async def team():
    return await make_team(PHONES)


async def matter(org_id: str, title: str, *, deleted: bool = False) -> str:
    [row] = await sql(
        "insert into public.matters (org_id, source, tracking, case_type, case_number, case_year, title, stage, "
        "deleted_at) values (:o, 'manual', 'manual', 'WP', :n, 2024, :t, 'Admission', "
        "case when :d then now() end) returning id::text",
        o=org_id, n=title.split()[-1], t=title, d=deleted,
    )  # fmt: skip
    return row["id"]


async def entry(org_id: str, matter_id: str, court: str, court_no: str, item_no: str, *, days: int = 1,
                current: bool = True, clash: int | None = None, assignee: str | None = None) -> None:  # fmt: skip
    await sql(
        "insert into public.board_entries (org_id, board_date, matter_id, court_id, court_no, item_no, clash_group, "
        "assignee_id, is_current, expected_slot) values (:o, :d, :m, :c, :cn, :i, :g, :a, :cur, '10:30')",
        o=org_id, d=today_ist() + timedelta(days=days), m=matter_id, c=court, cn=court_no, i=item_no, g=clash,
        a=assignee, cur=current,
    )  # fmt: skip


async def test_tomorrow_board_grouped_and_ordered(api, team):
    o = team.org_id
    m = {k: await matter(o, f"Test matter {k}") for k in ("j1", "j2", "j3", "j4", "i1", "d1", "today", "old")}
    gone = await matter(o, "Test matter gone", deleted=True)
    await entry(o, m["j1"], JABALPUR, "10", "3", clash=2)
    await entry(o, m["j2"], JABALPUR, "2", "S-12")
    await entry(o, m["j3"], JABALPUR, "2", "S-3")
    await entry(o, m["j4"], JABALPUR, "2", "7", clash=2)
    await entry(o, m["i1"], INDORE_HC, "1", "5", clash=1)
    await entry(o, m["d1"], INDORE_DC, "4", "1", clash=1, assignee=team.users["clerk"])
    await entry(o, m["today"], JABALPUR, "1", "1", days=0, clash=5)
    await entry(o, m["old"], JABALPUR, "1", "2", current=False, clash=6)
    await entry(o, gone, JABALPUR, "1", "3", clash=7)
    # The writer also owns another organisation; its board must not leak into this one.
    [other] = await sql(
        "insert into public.organizations (name, kind, owner_id) values ('Writer chamber', 'solo', :u) "
        "returning id::text",
        u=team.users["writer"],
    )
    elsewhere = await matter(other["id"], "Test matter elsewhere")
    await entry(other["id"], elsewhere, JABALPUR, "1", "4", clash=8)
    clients = await sql(
        "insert into public.clients (org_id, name, deleted_at) values "
        "(:o, 'Ravi Kumar', null), (:o, 'Asha Verma', null), (:o, 'Old Client', now()) returning id::text",
        o=o,
    )
    for c in clients:
        await sql(
            "insert into public.matter_clients (org_id, matter_id, client_id) values (:o, :m, :c)",
            o=o, m=m["j1"], c=c["id"],
        )  # fmt: skip

    r = await api.get("/v1/board/tomorrow", headers=team.h("writer"))
    assert r.status_code == 200, r.text
    board = r.json()
    assert board["date"] == (today_ist() + timedelta(days=1)).isoformat()
    assert board["clash_count"] == 2
    groups = board["groups"]
    assert [g["court_id"] for g in groups] == [INDORE_DC, INDORE_HC, JABALPUR]  # by court name
    assert groups[2]["short_name"] == "MPHC Jabalpur" and groups[2]["court_name_hi"]
    jabalpur = groups[2]["entries"]
    assert [e["matter_id"] for e in jabalpur] == [m["j4"], m["j3"], m["j2"], m["j1"]]
    assert [(e["court_no"], e["item_no"]) for e in jabalpur] == [("2", "7"), ("2", "S-3"), ("2", "S-12"), ("10", "3")]
    j1 = jabalpur[3]
    assert j1 | {"id": None, "matter_id": None} == {
        "id": None,
        "matter_id": None,
        "case_type": "WP",
        "case_number": "j1",
        "case_year": 2024,
        "cnr": None,
        "title": "Test matter j1",
        "stage": "Admission",
        "court_no": "10",
        "item_no": "3",
        "expected_slot": "10:30:00",
        "clash_group": 2,
        "proxy_arranged": False,
        "assignee": None,
        "clients": ["Asha Verma", "Ravi Kumar"],
    }
    [d1] = groups[0]["entries"]
    assert d1["assignee"] == {"user_id": team.users["clerk"], "display_name": "Clerk"}
    assert d1["clients"] == []
    shown = {e["matter_id"] for g in groups for e in g["entries"]}
    assert not shown & {m["today"], m["old"], gone, elsewhere}


def test_natural_sort_key():
    assert sorted(["S-12", "10", None, "2", "S-3"], key=natural) == ["2", "10", "S-3", "S-12", None]
    assert natural("3²") == (0, (0, 3, ""), (1, 0, "²"))  # superscripts are text, not numbers


async def test_tomorrow_board_needs_membership(api, team):
    r = await api.get("/v1/board/tomorrow", headers=team.h("outsider"))
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "NOT_A_MEMBER"


async def test_feedback(api, team):
    r = await api.post("/v1/feedback", json={"note": "Board loads slowly"}, headers=auth(team.tokens["owner"]))
    assert r.status_code == 201, r.text
    [row] = await sql(
        "select org_id, user_id::text, note, screen from public.feedback where id = :id", id=r.json()["id"]
    )
    assert row == {"org_id": None, "user_id": team.users["owner"], "note": "Board loads slowly", "screen": None}

    body = {"note": "Clash badge unclear", "screen": "board", "app_version": "1.0.0"}
    r = await api.post("/v1/feedback", json=body, headers=team.h("clerk"))
    assert r.status_code == 201, r.text
    [row] = await sql("select org_id::text, app_version from public.feedback where id = :id", id=r.json()["id"])
    assert row == {"org_id": team.org_id, "app_version": "1.0.0"}

    r = await api.post("/v1/feedback", json={"note": "hi"}, headers=team.h("outsider"))
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "NOT_A_MEMBER"
    assert (await api.post("/v1/feedback", json={"note": ""}, headers=team.h("owner"))).status_code == 422


async def test_feedback_rate_limit(api, team):
    h = auth(team.tokens["writer"])
    for _ in range(10):
        assert (await api.post("/v1/feedback", json={"note": "n"}, headers=h)).status_code == 201
    r = await api.post("/v1/feedback", json={"note": "n"}, headers=h)
    assert r.status_code == 429
    assert r.json()["error"]["code"] == "RATE_LIMITED"
