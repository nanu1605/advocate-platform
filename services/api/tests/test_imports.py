"""Import and jobs endpoints: find-cases, job status and cancel, found-case add and decisions (spec §4.1, §11.4)."""

import uuid
from datetime import date

import pytest

from advocate_api.ratelimit import redis
from advocate_shared import tasks

from .conftest import Team, auth, make_team, sql

PHONES = {
    "owner": ("919999900016", "owner"),
    "advocate": ("919999900017", "advocate"),
    "outsider": ("919999900018", None),
}
COURT = "c0000000-0000-0000-0000-000000000003"  # MPHC Indore (seed)
OTHER_COURT = "c0000000-0000-0000-0000-000000000005"  # District Court Indore


@pytest.fixture(scope="module")
async def team() -> Team:
    return await make_team(PHONES)


@pytest.fixture(scope="module")
async def other() -> Team:
    return await make_team({"owner": ("919999900019", "owner")})


def key() -> dict[str, str]:
    return {"Idempotency-Key": f"key-{uuid.uuid4()}"}


async def new_org(team: Team) -> dict[str, str]:
    """A fresh organisation owned by the team's owner (the owner membership comes from the org trigger)."""
    org_id = str(uuid.uuid4())
    await sql(
        "insert into public.organizations (id, name, kind, owner_id) values (:id, 'Import test', 'chamber', :o)",
        id=org_id, o=team.users["owner"],
    )  # fmt: skip
    return auth(team.tokens["owner"], **{"X-Org-Id": org_id})


def cnr() -> str:
    return f"TESTIMP{uuid.uuid4().hex[:9].upper()}"


async def found(org_id: str, user_id: str, cnr_: str | None = None, **cols) -> str:
    row = {
        "court_id": COURT, "case_type": "WP", "case_number": "101", "case_year": 2024, "court_no": "3",
        "title": "TEST Petitioner v. TEST Respondent", "next_date": None, "case_status": "pending",
        "confidence": "high", "decision": "pending", **cols,
    }  # fmt: skip
    [r] = await sql(
        "insert into public.found_cases (org_id, user_id, cnr, court_id, case_type, case_number, case_year, court_no, "
        "title, next_date, case_status, confidence, match_reason, source, decision) "
        "values (:o, :u, :c, :court_id, :case_type, :case_number, :case_year, :court_no, :title, "
        ":next_date, :case_status, :confidence, 'exact_name_practice_court', 'onboarding', :decision) "
        "returning id::text",
        o=org_id, u=user_id, c=cnr_ or cnr(), **row,
    )  # fmt: skip
    return r["id"]


async def job(team: Team, who: str, status: str = "queued") -> str:
    [r] = await sql(
        "insert into public.jobs (org_id, user_id, kind, status) values (:o, :u, 'find_cases', :s) returning id::text",
        o=team.org_id, u=team.users[who], s=status,
    )  # fmt: skip
    return r["id"]


async def state(org_id: str) -> tuple[list[dict], list[dict]]:
    matters = await sql(
        "select cnr, source, tracking, court_id::text, case_type, case_number, case_year, title, court_no, "
        "next_hearing_date, court_status, deleted_at is null as live from public.matters "
        "where org_id = :o order by cnr",
        o=org_id,
    )
    decisions = await sql("select cnr, decision from public.found_cases where org_id = :o order by cnr", o=org_id)
    return matters, decisions


async def test_find_cases_needs_profile(api, team):
    r = await api.post("/v1/onboarding/find-cases", headers=team.h("advocate", **key()))
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "PROFILE_INCOMPLETE"
    assert r.json()["error"]["details"] == {"missing": ["enrolment_no", "bar_council_state"]}


async def test_find_cases_creates_one_job(api, team, enqueued):
    await sql(
        "update public.profiles set enrolment_no = 'MP/1234/2010', bar_council_state = 'MP', "
        "practice_court_ids = array[cast(:c as uuid)] where id = :u",
        c=COURT, u=team.users["owner"],
    )  # fmt: skip
    h = team.h("owner", **key())
    r = await api.post("/v1/onboarding/find-cases", headers=h)
    assert r.status_code == 202, r.text
    job_id = r.json()["job_id"]
    assert r.json() == {"job_id": job_id, "status": "queued"}
    assert enqueued == [(tasks.FIND_CASES, job_id)]
    [row] = await sql("select kind, org_id::text, input from public.jobs where id = :id", id=job_id)
    assert row == {
        "kind": "find_cases",
        "org_id": team.org_id,
        "input": {
            "advocate_name": "Owner",
            "enrolment_no": "MP/1234/2010",
            "bar_council_state": "MP",
            "practice_court_ids": [COURT],
        },
    }

    replay = await api.post("/v1/onboarding/find-cases", headers=h)
    assert replay.status_code == 202 and replay.json() == r.json()
    assert replay.headers["Idempotent-Replay"] == "true"

    again = await api.post("/v1/onboarding/find-cases", headers=team.h("owner", **key()))
    assert again.status_code == 202 and again.json()["job_id"] == job_id  # still queued: same job
    assert len(enqueued) == 1

    await sql("update public.jobs set status = 'done' where id = :id", id=job_id)
    try:
        fresh = await api.post("/v1/onboarding/find-cases", headers=team.h("owner", **key()))
    finally:
        await redis().delete(f"rl:find-cases:{team.users['owner']}")
    assert fresh.status_code == 202 and fresh.json()["job_id"] != job_id
    assert enqueued[-1] == (tasks.FIND_CASES, fresh.json()["job_id"])


async def test_find_cases_daily_limit(api, team, enqueued):
    await sql(
        "update public.profiles set enrolment_no = 'MP/1234/2010', bar_council_state = 'MP' where id = :u",
        u=team.users["owner"],
    )
    h = await new_org(team)
    counter = f"rl:find-cases:{team.users['owner']}"
    await redis().set(counter, 3, ex=60)
    try:
        r = await api.post("/v1/onboarding/find-cases", headers={**h, **key()})
        assert r.status_code == 429 and r.json()["error"]["code"] == "RATE_LIMITED"
        assert await sql("select id from public.jobs where org_id = :o", o=h["X-Org-Id"]) == []
        # Returning the search already running doesn't count against the limit.
        [running] = await sql(
            "insert into public.jobs (org_id, user_id, kind, status) values (:o, :u, 'find_cases', 'running') "
            "returning id::text",
            o=h["X-Org-Id"], u=team.users["owner"],
        )  # fmt: skip
        same = await api.post("/v1/onboarding/find-cases", headers={**h, **key()})
        assert same.status_code == 202 and same.json() == {"job_id": running["id"], "status": "running"}
    finally:
        await redis().delete(counter)
    assert enqueued == []


async def test_get_job_visibility(api, team):
    job_id = await job(team, "advocate", "running")
    mine = await api.get(f"/v1/jobs/{job_id}", headers=auth(team.tokens["advocate"]))
    assert mine.status_code == 200
    body = mine.json()
    assert {k: body[k] for k in ("id", "kind", "status", "progress", "result", "error")} == {
        "id": job_id,
        "kind": "find_cases",
        "status": "running",
        "progress": {},
        "result": None,
        "error": None,
    }
    assert body["created_at"] and body["updated_at"]
    assert (await api.get(f"/v1/jobs/{job_id}", headers=auth(team.tokens["owner"]))).status_code == 200
    outsider = await api.get(f"/v1/jobs/{job_id}", headers=auth(team.tokens["outsider"]))
    assert outsider.status_code == 404 and outsider.json()["error"]["code"] == "NOT_FOUND"
    owners = await job(team, "owner")
    assert (await api.get(f"/v1/jobs/{owners}", headers=auth(team.tokens["advocate"]))).status_code == 404


async def test_cancel_job(api, team):
    job_id = await job(team, "advocate", "running")
    refused = await api.post(f"/v1/jobs/{job_id}/cancel", headers=auth(team.tokens["owner"]))
    assert refused.status_code == 403 and refused.json()["error"]["code"] == "ROLE_NOT_ALLOWED"
    hidden = await api.post(f"/v1/jobs/{job_id}/cancel", headers=auth(team.tokens["outsider"]))
    assert hidden.status_code == 404

    r = await api.post(f"/v1/jobs/{job_id}/cancel", headers=auth(team.tokens["advocate"]))
    assert r.status_code == 200 and r.json()["status"] == "cancelled"
    assert (await sql("select status from public.jobs where id = :id", id=job_id)) == [{"status": "cancelled"}]

    done = await job(team, "advocate", "done")
    finished = await api.post(f"/v1/jobs/{done}/cancel", headers=auth(team.tokens["advocate"]))
    assert finished.status_code == 409
    assert finished.json()["error"]["code"] == "JOB_FINISHED"
    assert finished.json()["error"]["details"] == {"status": "done"}


async def test_add_by_ids(api, team, enqueued):
    h = await new_org(team)
    org, me = h["X-Org-Id"], team.users["owner"]
    a = await found(org, me, next_date=date(2026, 11, 5), court_no="12")
    b = await found(org, me, decision="skipped")
    disposed = await found(org, me, case_status="disposed")
    not_mine = await found(org, me, decision="not_mine")

    r = await api.post("/v1/found-cases/add", headers={**h, **key()}, json={"ids": [a, b, disposed, not_mine]})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["added"] == 3 and body["already_tracked"] == 0 and len(body["matter_ids"]) == 3
    assert enqueued == [(tasks.FETCH_CASES, body["job_id"])]
    [j] = await sql("select kind, input from public.jobs where id = :id", id=body["job_id"])
    assert j["kind"] == "fetch_cases" and sorted(j["input"]["matter_ids"]) == sorted(body["matter_ids"])

    rows = await sql(
        "select m.id::text, m.source, m.tracking, m.court_id::text, m.next_hearing_date::text, m.court_no, "
        "m.court_status, f.decision from public.matters m join public.found_cases f on f.org_id = m.org_id "
        "and f.cnr = m.cnr where m.org_id = :o and f.id = :a",
        o=org, a=a,
    )  # fmt: skip
    assert rows == [
        {
            "id": rows[0]["id"],
            "source": "found",
            "tracking": "auto",
            "court_id": COURT,
            "next_hearing_date": "2026-11-05",
            "court_no": "12",
            "court_status": "pending",
            "decision": "added",
        }
    ]
    assert rows[0]["id"] in body["matter_ids"]
    decisions = await sql("select id::text, decision from public.found_cases where org_id = :o", o=org)
    assert {d["id"]: d["decision"] for d in decisions} == {
        a: "added",
        b: "added",
        disposed: "added",
        not_mine: "not_mine",
    }


async def test_add_validation(api, team):
    h = {**team.h("owner"), **key()}
    for bad in ({}, {"ids": [str(uuid.uuid4())], "all": True}, {"ids": []}, {"filter": {}}, {"all": False}):
        r = await api.post("/v1/found-cases/add", headers=h, json=bad)
        assert r.status_code == 422, bad
    too_many = {"ids": [str(uuid.uuid4()) for _ in range(501)]}
    assert (await api.post("/v1/found-cases/add", headers=h, json=too_many)).status_code == 422


async def test_add_all_with_filter(api, team, enqueued):
    h = await new_org(team)
    org, me = h["X-Org-Id"], team.users["owner"]
    want = {
        await found(org, me, "TESTFLT000000001"),
        await found(org, me, "TESTFLT000000002", decision="skipped"),
    }
    await found(org, me, "TESTFLT000000003", confidence="low")
    await found(org, me, "TESTFLT000000004", court_id=OTHER_COURT)
    await found(org, me, "TESTFLT000000005", case_year=2023)
    await found(org, me, "TESTFLT000000006", case_status="disposed")
    await found(org, me, "TESTFLT000000007", decision="not_mine")

    r = await api.post(
        "/v1/found-cases/add",
        headers={**h, **key()},
        json={"all": True, "filter": {"court_id": COURT, "case_year": 2024, "confidence": "high"}},
    )
    assert r.status_code == 200, r.text
    assert r.json()["added"] == 2
    added = await sql("select id::text from public.found_cases where org_id = :o and decision = 'added'", o=org)
    assert {a["id"] for a in added} == want
    matters = await sql("select cnr from public.matters where org_id = :o order by cnr", o=org)
    assert matters == [{"cnr": "TESTFLT000000001"}, {"cnr": "TESTFLT000000002"}]
    assert len(enqueued) == 1


async def test_add_all_and_add_selected_match(api, team, enqueued):
    async def setup() -> tuple[dict[str, str], list[str]]:
        h = await new_org(team)
        org, me = h["X-Org-Id"], team.users["owner"]
        pending = [
            await found(org, me, "TESTSAM000000001", next_date=date(2026, 11, 2)),
            await found(org, me, "TESTSAM000000002", confidence="low"),
            await found(org, me, "TESTSAM000000003", decision="skipped", court_id=OTHER_COURT),
            await found(org, me, "TESTSAM000000004"),
        ]
        await found(org, me, "TESTSAM000000005", case_status="disposed")
        await found(org, me, "TESTSAM000000006", decision="not_mine")
        await sql(
            "insert into public.matters (org_id, source, tracking, cnr) values (:o, 'cnr', 'auto', 'TESTSAM000000004')",
            o=org,
        )
        return h, pending

    h_all, _ = await setup()
    h_sel, pending = await setup()
    by_all = await api.post("/v1/found-cases/add", headers={**h_all, **key()}, json={"all": True})
    by_ids = await api.post("/v1/found-cases/add", headers={**h_sel, **key()}, json={"ids": pending})
    assert by_all.status_code == by_ids.status_code == 200
    for r in (by_all, by_ids):
        assert (r.json()["added"], r.json()["already_tracked"]) == (3, 1)
    assert await state(h_all["X-Org-Id"]) == await state(h_sel["X-Org-Id"])
    matters, decisions = await state(h_all["X-Org-Id"])
    assert [m["cnr"] for m in matters] == [f"TESTSAM00000000{i}" for i in (1, 2, 3, 4)]
    assert [d["decision"] for d in decisions] == ["added"] * 4 + ["pending", "not_mine"]
    assert [t for t, _ in enqueued] == [tasks.FETCH_CASES] * 2


async def test_allowance_exceeded_changes_nothing(api, team, enqueued):
    h = await new_org(team)
    org, me = h["X-Org-Id"], team.users["owner"]
    [cfg] = await sql(
        "select (value #>> '{}')::int as cap from public.app_config where key = 'beta_tracked_case_allowance'"
    )
    cap = cfg["cap"]
    await sql(
        "insert into public.matters (org_id, source, tracking, cnr) "
        "select :o, 'cnr', 'auto', 'TESTCAP' || lpad(g::text, 9, '0') from generate_series(1, :n) g",
        o=org, n=cap - 1,
    )  # fmt: skip
    ids = [await found(org, me), await found(org, me)]

    r = await api.post("/v1/found-cases/add", headers={**h, **key()}, json={"ids": ids})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "TRACKED_CASE_LIMIT"
    assert r.json()["error"]["details"] == {"limit": cap, "remaining": 1}
    [count] = await sql("select count(*) as n from public.matters where org_id = :o", o=org)
    assert count["n"] == cap - 1
    pending = await sql("select decision from public.found_cases where org_id = :o", o=org)
    assert [p["decision"] for p in pending] == ["pending", "pending"]
    assert enqueued == []

    one = await api.post("/v1/found-cases/add", headers={**h, **key()}, json={"ids": ids[:1]})
    assert one.status_code == 200 and one.json()["added"] == 1


async def test_add_already_tracked_and_restore(api, team, enqueued):
    h = await new_org(team)
    org, me = h["X-Org-Id"], team.users["owner"]
    tracked, deleted, new = cnr(), cnr(), cnr()
    ids = [await found(org, me, c) for c in (tracked, deleted, new)]
    [live] = await sql(
        "insert into public.matters (org_id, source, tracking, cnr) values (:o, 'cnr', 'auto', :c) returning id::text",
        o=org, c=tracked,
    )  # fmt: skip
    [gone] = await sql(
        "insert into public.matters (org_id, source, tracking, cnr, deleted_at) "
        "values (:o, 'cnr', 'off', :c, now()) returning id::text",
        o=org, c=deleted,
    )  # fmt: skip

    r = await api.post("/v1/found-cases/add", headers={**h, **key()}, json={"ids": ids})
    assert r.status_code == 200, r.text
    body = r.json()
    assert (body["added"], body["already_tracked"]) == (2, 1)
    assert gone["id"] in body["matter_ids"] and live["id"] not in body["matter_ids"]
    [restored] = await sql("select source, tracking, deleted_at from public.matters where id = :id", id=gone["id"])
    assert restored == {"source": "cnr", "tracking": "auto", "deleted_at": None}
    [j] = await sql("select input from public.jobs where id = :id", id=body["job_id"])
    assert sorted(j["input"]["matter_ids"]) == sorted(body["matter_ids"])
    decisions = await sql("select decision from public.found_cases where org_id = :o", o=org)
    assert [d["decision"] for d in decisions] == ["added"] * 3

    # Everything already tracked: nothing to fetch.
    again = await found(org, me, decision="skipped")
    await sql(
        "insert into public.matters (org_id, source, tracking, cnr) "
        "select org_id, 'cnr', 'auto', cnr from public.found_cases where id = :id",
        id=again,
    )
    only = await api.post("/v1/found-cases/add", headers={**h, **key()}, json={"ids": [again]})
    assert only.json() == {"added": 0, "already_tracked": 1, "matter_ids": [], "job_id": None}
    assert len(enqueued) == 1


async def test_add_ignores_other_orgs(api, team, other, enqueued):
    h = await new_org(team)
    org, me = h["X-Org-Id"], team.users["owner"]
    mine = await found(org, me)
    elsewhere = await found(team.org_id, me)  # the caller's other organisation
    theirs = await found(other.org_id, other.users["owner"])

    r = await api.post("/v1/found-cases/add", headers={**h, **key()}, json={"ids": [mine, elsewhere, theirs]})
    assert r.status_code == 200, r.text
    assert (r.json()["added"], r.json()["already_tracked"], len(r.json()["matter_ids"])) == (1, 0, 1)
    rows = await sql(
        "select id::text, decision from public.found_cases where id = any(cast(:ids as uuid[]))",
        ids=[mine, elsewhere, theirs],
    )
    assert {x["id"]: x["decision"] for x in rows} == {mine: "added", elsewhere: "pending", theirs: "pending"}
    stray = await sql(
        "select m.cnr from public.matters m join public.found_cases f on f.cnr = m.cnr "
        "where m.org_id = :o and f.id in (:e, :t)",
        o=org, e=elsewhere, t=theirs,
    )  # fmt: skip
    assert stray == []


async def test_decision(api, team, other):
    h = await new_org(team)
    org, me = h["X-Org-Id"], team.users["owner"]
    fc = await found(org, me)
    r = await api.post(f"/v1/found-cases/{fc}/decision", headers=h, json={"decision": "not_mine"})
    assert r.status_code == 200 and r.json() == {"id": fc, "decision": "not_mine"}
    assert (await sql("select decision from public.found_cases where id = :id", id=fc)) == [{"decision": "not_mine"}]

    added = await api.post(f"/v1/found-cases/{fc}/decision", headers=h, json={"decision": "added"})
    assert added.status_code == 422

    # A tracked case can't come back into "Found for you" or be excluded while still tracked.
    tracked = await found(org, me, decision="added")
    [case] = await sql("select cnr from public.found_cases where id = :id", id=tracked)
    [matter] = await sql(
        "insert into public.matters (org_id, source, tracking, cnr) values (:o, 'found', 'manual', :c) returning id",
        o=org,
        c=case["cnr"],
    )
    for d in ("pending", "not_mine"):
        r = await api.post(f"/v1/found-cases/{tracked}/decision", headers=h, json={"decision": d})
        assert r.status_code == 409 and r.json()["error"]["code"] == "FOUND_CASE_ADDED"
    assert (await sql("select decision from public.found_cases where id = :id", id=tracked)) == [{"decision": "added"}]
    # Once its matter is deleted, the case can be decided again.
    await sql("update public.matters set deleted_at = now() where id = :id", id=matter["id"])
    again = await api.post(f"/v1/found-cases/{tracked}/decision", headers=h, json={"decision": "not_mine"})
    assert again.status_code == 200 and again.json()["decision"] == "not_mine"

    theirs = await found(other.org_id, other.users["owner"])
    hidden = await api.post(f"/v1/found-cases/{theirs}/decision", headers=h, json={"decision": "skipped"})
    assert hidden.status_code == 404 and hidden.json()["error"]["code"] == "NOT_FOUND"
    # A found case in another of the caller's organisations is not in this X-Org-Id's.
    elsewhere = await found(team.org_id, me)
    wrong_org = await api.post(f"/v1/found-cases/{elsewhere}/decision", headers=h, json={"decision": "skipped"})
    assert wrong_org.status_code == 404
    assert (await sql("select decision from public.found_cases where id = :id", id=theirs)) == [{"decision": "pending"}]
