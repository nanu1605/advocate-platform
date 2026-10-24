"""Case endpoints (spec §10.2): search, add by CNR or by hand, refresh, tracking on/off, official link and delete."""

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import date

import pytest

from advocate_api.ratelimit import redis
from advocate_api.routes import matters
from advocate_api.routes.matters import search_cache_key
from advocate_shared import tasks
from advocate_shared.ist import today_ist
from court_data.models import CaseSearchQuery

from .conftest import make_team, sql

PHONES = {
    "owner": ("919999900020", "owner"),
    "advocate": ("919999900021", "advocate"),
    "clerk": ("919999900022", "clerk"),
    "outsider": ("919999900023", None),
}
NEHA = {"advocate": "Neha Sharma"}
SC_COURT = "c0000000-0000-0000-0000-000000000001"


@pytest.fixture(scope="module")
async def team():
    return await make_team(PHONES)


def idem(team, who: str = "owner") -> dict[str, str]:
    return team.h(who, **{"Idempotency-Key": f"key-{uuid.uuid4()}"})


def new_cnr(prefix: str = "MTRS") -> str:
    return f"{prefix}{uuid.uuid4().int % 10**12:012d}"


async def add_matter(team, cnr: str | None, tracking: str = "auto", court_id: str | None = None) -> str:
    [row] = await sql(
        "insert into public.matters (org_id, source, tracking, cnr, court_id) values (:o, :s, :t, :c, :court) "
        "returning id::text",
        o=team.org_id, s="manual" if tracking == "manual" else "cnr", t=tracking, c=cnr, court=court_id,
    )  # fmt: skip
    return row["id"]


@pytest.fixture
def slow_jobs(monkeypatch) -> None:
    """Holds each request just before it creates its job, so two concurrent requests overlap there."""
    real = matters.create_job

    async def slow(*args, **kwargs):
        await asyncio.sleep(0.2)
        return await real(*args, **kwargs)

    monkeypatch.setattr(matters, "create_job", slow)


@pytest.fixture(scope="module")
async def other_org(team) -> AsyncIterator[str]:
    """The outsider's organisation, where the team's owner is also an advocate: only X-Org-Id keeps them apart."""
    org_id = str(uuid.uuid4())
    await sql(
        "insert into public.organizations (id, name, kind, owner_id) values (:id, 'Other chamber', 'chamber', :o)",
        id=org_id, o=team.users["outsider"],
    )  # fmt: skip
    await sql(
        "insert into public.memberships (org_id, user_id, role, display_name) values (:o, :u, 'advocate', 'Owner')",
        o=org_id, u=team.users["owner"],
    )  # fmt: skip
    yield org_id
    await sql("delete from public.provider_calls where org_id = :id", id=org_id)
    await sql("delete from public.organizations where id = :id", id=org_id)


async def search_calls(team) -> int:
    [row] = await sql(
        "select count(*) as n from public.provider_calls where org_id = :o and operation = 'search'", o=team.org_id
    )
    return row["n"]


def code(r) -> str:
    return r.json()["error"]["code"]


async def test_search_flags_tracked_cases_and_caches(api, team):
    await redis().delete(search_cache_key(CaseSearchQuery(advocate="Neha Sharma", page=1, page_size=20)))
    await add_matter(team, "TEST010000012024")
    deleted = await add_matter(team, "TEST020000022024")
    await sql("update public.matters set deleted_at = now() where id = :id", id=deleted)
    before = await search_calls(team)

    r = await api.post("/v1/search/cases", json=NEHA, headers=team.h("owner"))
    assert r.status_code == 200, r.text
    body = r.json()
    assert (body["cached"], body["total"], body["page"], body["has_next"]) == (False, 8, 1, False)
    assert (body["post_filtered"], body["ignored_court_ids"]) == (False, [])
    tracked = {h["cnr"]: h["tracked"] for h in body["items"]}
    assert tracked["TEST010000012024"] is True
    assert tracked["TEST020000022024"] is False  # soft-deleted
    assert sum(tracked.values()) == 1
    hit = next(h for h in body["items"] if h["cnr"] == "TEST010000012024")
    assert {"name": "Neha Sharma", "side": "petitioner"} in hit["advocates"]
    assert hit["case_type"] == "WP" and hit["case_year"] == 2024
    assert await search_calls(team) == before + 1

    again = await api.post("/v1/search/cases", json={"advocate": "  NEHA sharma "}, headers=team.h("advocate"))
    assert again.json()["cached"] is True
    assert again.json()["items"] == body["items"]
    assert await search_calls(team) == before + 1  # served from the cache

    narrowed = await api.post(
        "/v1/search/cases", json=NEHA | {"case_type": "wp", "year": 2024}, headers=team.h("owner")
    )
    assert narrowed.json()["cached"] is True
    assert {h["cnr"] for h in narrowed.json()["items"]} == {"TEST010000012024", "TEST070000072024", "TEST080000082024"}
    assert (narrowed.json()["total"], narrowed.json()["post_filtered"]) == (8, True)

    # Seeded courts have no provider code yet (and an unknown id has none either): reported, not silently dropped.
    unknown = str(uuid.uuid4())
    courts = await api.post(
        "/v1/search/cases", json=NEHA | {"court_ids": [SC_COURT, unknown, SC_COURT]}, headers=team.h("owner")
    )
    assert courts.json()["ignored_court_ids"] == [SC_COURT, unknown]
    assert courts.json()["items"] == body["items"]


async def test_search_needs_a_term(api, team):
    r = await api.post("/v1/search/cases", json={"party": "  ", "case_type": "WP"}, headers=team.h("owner"))
    assert r.status_code == 422
    assert code(r) == "SEARCH_TERMS_REQUIRED"


async def test_search_minute_limit_and_daily_cap(api, team):
    minute = f"rl:search:{team.users['clerk']}"
    await redis().set(minute, 30, ex=60)
    try:
        r = await api.post("/v1/search/cases", json=NEHA, headers=team.h("clerk"))
    finally:
        await redis().delete(minute)
    assert r.status_code == 429
    assert code(r) == "RATE_LIMITED"

    [cfg] = await sql(
        "select (value #>> '{}')::int as cap from public.app_config where key = 'beta_case_search_daily_cap'"
    )
    day = f"rl:search-day:{team.org_id}:{today_ist()}"
    await redis().set(day, cfg["cap"], ex=60)
    try:
        r = await api.post("/v1/search/cases", json=NEHA, headers=team.h("owner"))
    finally:
        await redis().delete(day)
    assert r.status_code == 429
    assert r.json()["error"] == {
        "code": "SEARCH_DAILY_CAP",
        "message": "Today's case searches are used up",
        "retryable": False,
        "details": {"limit": cfg["cap"]},
    }


async def test_add_by_cnr(api, team, enqueued):
    bad = await api.post("/v1/matters/by-cnr", json={"cnr": "MPHC-0100"}, headers=idem(team))
    assert bad.status_code == 422
    assert code(bad) == "INVALID_CNR"

    cnr = new_cnr()
    typed = f" {cnr[:4].lower()}-{cnr[4:10]} {cnr[10:]}"
    r = await api.post("/v1/matters/by-cnr", json={"cnr": typed}, headers=idem(team, "clerk"))
    assert r.status_code == 200, r.text
    added = r.json()
    assert added["created"] is True and added["job_id"]
    assert enqueued == [(tasks.FETCH_CASES, added["job_id"])]
    [matter] = await sql("select cnr, source, tracking from public.matters where id = :id", id=added["matter_id"])
    assert matter == {"cnr": cnr, "source": "cnr", "tracking": "auto"}
    [job] = await sql("select kind, input from public.jobs where id = :id", id=added["job_id"])
    assert job == {"kind": "fetch_cases", "input": {"matter_ids": [added["matter_id"]]}}

    again = await api.post("/v1/matters/by-cnr", json={"cnr": cnr}, headers=idem(team))
    assert again.json() == {"matter_id": added["matter_id"], "created": False, "job_id": None}
    assert len(enqueued) == 1

    await sql("update public.matters set deleted_at = now(), tracking = 'off' where id = :id", id=added["matter_id"])
    restored = await api.post("/v1/matters/by-cnr", json={"cnr": cnr}, headers=idem(team))
    assert restored.json()["matter_id"] == added["matter_id"]
    assert restored.json()["created"] is True
    assert enqueued[1] == (tasks.FETCH_CASES, restored.json()["job_id"])
    [matter] = await sql("select deleted_at, tracking from public.matters where id = :id", id=added["matter_id"])
    assert matter == {"deleted_at": None, "tracking": "auto"}


async def test_add_by_cnr_concurrently_creates_once(api, team, enqueued, slow_jobs):
    cnr = new_cnr()
    adds = await asyncio.gather(*(api.post("/v1/matters/by-cnr", json={"cnr": cnr}, headers=idem(team)) for _ in "ab"))
    assert [r.status_code for r in adds] == [200, 200], [r.text for r in adds]
    assert sorted(r.json()["created"] for r in adds) == [False, True]
    assert len({r.json()["matter_id"] for r in adds}) == 1
    assert len(enqueued) == 1

    await sql("update public.matters set deleted_at = now() where id = :id", id=adds[0].json()["matter_id"])
    restores = await asyncio.gather(
        *(api.post("/v1/matters/by-cnr", json={"cnr": cnr}, headers=idem(team)) for _ in "ab")
    )
    assert sorted(r.json()["created"] for r in restores) == [False, True], [r.text for r in restores]
    assert len(enqueued) == 2


async def test_manual_case_with_next_date(api, team):
    body = {
        "title": "Demo Petitioner v. Demo Respondent",
        "court_name": "Family Court, Dewas",
        "case_type": "HMA",
        "case_number": "12",
        "case_year": 2025,
        "our_side": "petitioner",
        "next_date": "2026-11-20",
    }
    r = await api.post("/v1/matters/manual", json=body, headers=team.h("clerk"))
    assert r.status_code == 201, r.text
    matter = r.json()
    assert (matter["source"], matter["tracking"], matter["cnr"]) == ("manual", "manual", None)
    assert matter["court_name"] == "Family Court, Dewas" and matter["title"] == body["title"]
    hearings = await sql("select date, source from public.hearings where matter_id = :m", m=matter["id"])
    assert hearings == [{"date": date(2026, 11, 20), "source": "manual"}]

    listed = await api.post(
        "/v1/matters/manual", json={"title": "Demo v. State", "court_id": SC_COURT}, headers=team.h("owner")
    )
    assert listed.status_code == 201
    assert listed.json()["court_id"] == SC_COURT

    no_court = await api.post("/v1/matters/manual", json={"title": "Demo v. State"}, headers=team.h("owner"))
    assert code(no_court) == "COURT_REQUIRED"
    unknown = await api.post(
        "/v1/matters/manual", json={"title": "Demo v. State", "court_id": str(uuid.uuid4())}, headers=team.h("owner")
    )
    assert code(unknown) == "UNKNOWN_COURT"
    blank = await api.post("/v1/matters/manual", json={"title": "  ", "court_name": "X"}, headers=team.h("owner"))
    assert code(blank) == "VALIDATION_ERROR"


async def test_refresh(api, team, enqueued, slow_jobs):
    manual = await add_matter(team, None, tracking="manual")
    r = await api.post(f"/v1/matters/{manual}/refresh", headers=idem(team))
    assert r.status_code == 409
    assert code(r) == "MANUAL_CASE"
    off = await add_matter(team, new_cnr(), tracking="off")
    assert code(await api.post(f"/v1/matters/{off}/refresh", headers=idem(team))) == "TRACKING_OFF"
    missing = await api.post(f"/v1/matters/{uuid.uuid4()}/refresh", headers=idem(team))
    assert missing.status_code == 404

    matter = await add_matter(team, new_cnr())
    r = await api.post(f"/v1/matters/{matter}/refresh", headers=idem(team, "clerk"))
    assert r.status_code == 202, r.text
    job_id = r.json()["job_id"]
    assert enqueued == [(tasks.REFRESH_CASE, job_id)]
    [job] = await sql("select kind, input from public.jobs where id = :id", id=job_id)
    assert job == {"kind": "refresh_case", "input": {"matter_id": matter}}

    again = await api.post(f"/v1/matters/{matter}/refresh", headers=idem(team))
    assert again.status_code == 429
    assert code(again) == "RATE_LIMITED"
    assert 0 < again.json()["error"]["details"]["retry_after_s"] <= 6 * 3600
    assert len(enqueued) == 1

    racing = await add_matter(team, new_cnr())
    both = await asyncio.gather(*(api.post(f"/v1/matters/{racing}/refresh", headers=idem(team)) for _ in "ab"))
    assert sorted(r.status_code for r in both) == [202, 429]
    assert len(enqueued) == 2


async def test_other_organisations_cases(api, team, other_org, enqueued):
    [row] = await sql(
        "insert into public.matters (org_id, source, tracking, cnr) values (:o, 'cnr', 'auto', :c) returning id::text",
        o=other_org, c=new_cnr(),
    )  # fmt: skip
    theirs = row["id"]
    for who, status, err in (("owner", 404, "NOT_FOUND"), ("outsider", 403, "NOT_A_MEMBER")):
        h = idem(team, who)
        for r in (
            await api.post(f"/v1/matters/{theirs}/refresh", headers=h),
            await api.patch(f"/v1/matters/{theirs}", json={"tracking": "off"}, headers=h),
            await api.get(f"/v1/matters/{theirs}/official-link", headers=h),
            await api.delete(f"/v1/matters/{theirs}", headers=h),
        ):
            assert (r.status_code, code(r)) == (status, err), (who, r.request.method, r.text)
    assert enqueued == []
    assert await sql("select deleted_at, tracking from public.matters where id = :id", id=theirs) == [
        {"deleted_at": None, "tracking": "auto"}
    ]


async def tracking_of(matter: str) -> str:
    [row] = await sql("select tracking from public.matters where id = :id", id=matter)
    return row["tracking"]


async def test_tracking_on_and_off(api, team, enqueued):
    async def patch(matter: str, tracking: str, who: str = "clerk"):
        return await api.patch(f"/v1/matters/{matter}", json={"tracking": tracking}, headers=team.h(who))

    manual = await add_matter(team, None, tracking="manual")
    assert (r := await patch(manual, "off")).status_code == 409 and code(r) == "MANUAL_CASE"
    no_cnr = await add_matter(team, None, tracking="off")
    assert (r := await patch(no_cnr, "auto")).status_code == 409 and code(r) == "NO_CNR"
    assert code(await patch(manual, "manual")) == "VALIDATION_ERROR"
    assert (await patch(str(uuid.uuid4()), "off")).status_code == 404

    m = await add_matter(team, new_cnr())
    r = await patch(m, "off")  # every role (§15.3 add/edit matters)
    assert r.status_code == 200, r.text
    assert r.json() == {"matter_id": m, "tracking": "off", "job_id": None}
    assert await tracking_of(m) == "off"
    assert (await patch(m, "off")).json()["job_id"] is None  # unchanged: a no-op

    on = await patch(m, "auto")
    assert on.json()["tracking"] == "auto" and on.json()["job_id"]
    assert enqueued == [(tasks.FETCH_CASES, on.json()["job_id"])]
    [job] = await sql("select kind, input from public.jobs where id = :id", id=on.json()["job_id"])
    assert job == {"kind": "fetch_cases", "input": {"matter_ids": [m]}}
    assert await tracking_of(m) == "auto"
    assert (await patch(m, "auto")).json()["job_id"] is None

    # Off and on again within 6 h: the fetch is claimed like a refresh, so no second one (and Refresh says so).
    await patch(m, "off")
    assert (await patch(m, "auto")).json() == {"matter_id": m, "tracking": "auto", "job_id": None}
    assert code(await api.post(f"/v1/matters/{m}/refresh", headers=idem(team))) == "RATE_LIMITED"
    # Fetched by the worker in the last 6 h: nothing to fetch either.
    fresh = await add_matter(team, new_cnr(), tracking="off")
    await sql("update public.matters set court_fetched_at = now() - interval '1 hour' where id = :id", id=fresh)
    assert (await patch(fresh, "auto", "owner")).json()["job_id"] is None
    assert len(enqueued) == 1


async def test_tracking_on_respects_the_allowance(api, team, enqueued):
    o = team.org_id
    off = await add_matter(team, new_cnr(), tracking="off")
    [cfg] = await sql(
        "select (value #>> '{}')::int as n from public.app_config where key = 'beta_tracked_case_allowance'"
    )
    [used] = await sql(
        "select count(*) as n from public.matters where org_id = :o and tracking = 'auto' and deleted_at is null", o=o
    )
    await sql(
        "insert into public.matters (org_id, source, tracking, cnr) "
        "select :o, 'cnr', 'auto', 'FULL' || lpad(g::text, 12, '0') from generate_series(1, :k) g",
        o=o, k=cfg["n"] - used["n"],
    )  # fmt: skip
    try:
        r = await api.patch(f"/v1/matters/{off}", json={"tracking": "auto"}, headers=team.h("advocate"))
        assert r.status_code == 409, r.text
        assert r.json()["error"]["code"] == "TRACKED_CASE_LIMIT"
        assert r.json()["error"]["details"] == {"limit": cfg["n"]}
        assert await tracking_of(off) == "off"
        assert enqueued == []
    finally:
        await sql("delete from public.matters where org_id = :o and cnr like 'FULL%'", o=o)


async def test_official_link(api, team):
    hc_cnr = new_cnr("MPHC")
    hc = await add_matter(team, hc_cnr)
    r = await api.get(f"/v1/matters/{hc}/official-link", headers=team.h("clerk"))
    assert r.status_code == 200, r.text
    assert r.json() == {"url": "https://hcservices.ecourts.gov.in/", "cnr": hc_cnr, "verified": False}

    sc = await add_matter(team, new_cnr(), court_id=SC_COURT)
    assert (await api.get(f"/v1/matters/{sc}/official-link", headers=team.h("owner"))).json()["url"] == (
        "https://www.sci.gov.in/"
    )
    dc = await add_matter(team, new_cnr("MPIN"))
    assert (await api.get(f"/v1/matters/{dc}/official-link", headers=team.h("owner"))).json()["url"] == (
        "https://services.ecourts.gov.in/"
    )
    manual = await add_matter(team, None, tracking="manual")
    assert code(await api.get(f"/v1/matters/{manual}/official-link", headers=team.h("owner"))) == "NO_CNR"


async def test_delete_soft_deletes_children_and_frees_allowance(api, team, enqueued):
    m = await add_matter(team, new_cnr())
    o, owner, adv = team.org_id, team.users["owner"], team.users["advocate"]
    for statement in (
        "insert into public.hearings (org_id, matter_id, date, source) values (:o, :m, current_date, 'court')",
        "insert into public.orders (org_id, matter_id, title) values (:o, :m, 'Order')",
        "insert into public.notes (org_id, matter_id, author_id, body, visibility) "
        "values (:o, :m, :owner, 'team note', 'team'), (:o, :m, :adv, 'private note', 'private')",
        "insert into public.tasks (org_id, matter_id, title) values (:o, :m, 'File reply')",
        "insert into public.deadlines (org_id, matter_id, kind, due_date) values (:o, :m, 'filing', current_date + 7)",
        "insert into public.documents (org_id, matter_id, title) values (:o, :m, 'Petition')",
        "insert into public.board_entries (org_id, board_date, matter_id) values (:o, current_date + 1, :m)",
        "insert into public.org_cause_list_entries (org_id, matter_id, list_date) values (:o, :m, current_date + 1)",
    ):
        params = {"o": o, "m": m} | ({"owner": owner, "adv": adv} if ":owner" in statement else {})
        await sql(statement, **params)
    gone_cnr = new_cnr()
    gone = await add_matter(team, gone_cnr)
    await sql("update public.matters set deleted_at = now() where id = :id", id=gone)

    clerk = await api.delete(f"/v1/matters/{m}", headers=team.h("clerk"))
    assert clerk.status_code == 403
    assert code(clerk) == "ROLE_NOT_ALLOWED"

    [cfg] = await sql(
        "select (value #>> '{}')::int as n from public.app_config where key = 'beta_tracked_case_allowance'"
    )
    [used] = await sql(
        "select count(*) as n from public.matters where org_id = :o and tracking = 'auto' and deleted_at is null", o=o
    )
    await sql(
        "insert into public.matters (org_id, source, tracking, cnr) "
        "select :o, 'cnr', 'auto', 'FILL' || lpad(g::text, 12, '0') from generate_series(1, :k) g",
        o=o, k=cfg["n"] - used["n"],
    )  # fmt: skip
    try:
        cnr = new_cnr()
        full = await api.post("/v1/matters/by-cnr", json={"cnr": cnr}, headers=idem(team))
        assert full.status_code == 409
        assert code(full) == "TRACKED_CASE_LIMIT"
        restore = await api.post("/v1/matters/by-cnr", json={"cnr": gone_cnr}, headers=idem(team))
        assert (restore.status_code, code(restore)) == (409, "TRACKED_CASE_LIMIT")
        assert (await sql("select deleted_at is not null as gone from public.matters where id = :id", id=gone)) == [
            {"gone": True}
        ]
        assert enqueued == []

        r = await api.delete(f"/v1/matters/{m}", headers=team.h("owner"))
        assert r.status_code == 204, r.text
        for table in ("hearings", "orders", "notes", "tasks", "deadlines", "documents"):
            rows = await sql(f"select deleted_at is not null as gone from public.{table} where matter_id = :m", m=m)
            assert len(rows) == (2 if table == "notes" else 1) and all(r["gone"] for r in rows), table
        for table in ("board_entries", "org_cause_list_entries"):
            assert await sql(f"select is_current from public.{table} where matter_id = :m", m=m) == [
                {"is_current": False}
            ], table
        audit = await sql("select action, user_id::text from public.audit_log where entity_id = :m", m=m)
        assert audit == [{"action": "matter_deleted", "user_id": owner}]

        freed = await api.post("/v1/matters/by-cnr", json={"cnr": cnr}, headers=idem(team))
        assert freed.status_code == 200, freed.text
        assert freed.json()["created"] is True

        twice = await api.delete(f"/v1/matters/{m}", headers=team.h("advocate"))
        assert twice.status_code == 404
    finally:
        await sql("delete from public.matters where org_id = :o and cnr like 'FILL%'", o=o)
