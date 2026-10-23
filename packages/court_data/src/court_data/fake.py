"""Local stand-in for the eCourtsIndia API, built from synthetic cases (CNRs start with TEST, names are made up).
Tests and local runs use it while COURTDATA_LIVE=0 and the founder's provider account is on hold. Spike 11e adds
recorded responses for the contract tests; this stays for offline development."""

import json
import re
from datetime import date, timedelta
from functools import partial
from pathlib import Path
from typing import Any

import httpx

ANCHOR = date(2026, 10, 26)  # "today" in the synthetic data: three matters are listed the next day
DATA = Path(__file__).parent / "fixtures" / "ecourtsindia_synthetic.json"
Case = dict[str, Any]


def synthetic_transport(today: date | None = None) -> httpx.MockTransport:
    """`today` moves every date in the data by the same offset, so local boards always have a "tomorrow"."""
    text = DATA.read_text(encoding="utf-8")
    if today:
        shift = timedelta(days=(today - ANCHOR).days)
        text = re.sub(r"\d{4}-\d{2}-\d{2}", lambda m: (date.fromisoformat(m[0]) + shift).isoformat(), text)
    cases = {c["courtCaseData"]["cnr"]: c for c in json.loads(text)}
    return httpx.MockTransport(partial(_handle, cases))


def _handle(cases: dict[str, Case], request: httpx.Request) -> httpx.Response:
    parts = request.url.path.split("/api/partner", 1)[-1].strip("/").split("/")
    q = request.url.params
    match request.method, parts:
        case "GET", ["search"]:
            rows = [c for c in cases.values() if _matches(c["courtCaseData"], q)]
            page, size = int(q.get("page", 1)), int(q.get("pageSize", 50))
            data = {
                "results": [_search_item(c) for c in rows[(page - 1) * size : page * size]],
                "totalHits": len(rows),
                "page": page,
                "pageSize": size,
                "hasNextPage": page * size < len(rows),
            }
            return _ok(data)
        case "GET", ["case", cnr] if cnr in cases:
            return _ok({k: v for k, v in cases[cnr].items() if not k.startswith("_")})
        case "POST", ["case", "bulk-refresh"]:
            cnrs = json.loads(request.content)["cnrs"]
            known = [c for c in cnrs if c in cases]
            return _ok({"refreshed": [], "queued": known, "invalid": [c for c in cnrs if c not in cases]})
        case "POST", ["case", cnr, "refresh"] if cnr in cases:
            return _ok({"cnr": cnr, "status": "QUEUED", "message": "Refresh queued", "estimatedTime": "5-10s"}, 202)
        case "GET", ["case", cnr, "order", name] if cnr in cases and name in _order_files(cases[cnr]):
            return httpx.Response(
                200, content=_pdf(f"Synthetic order {name} in {cnr}"), headers={"content-type": "application/pdf"}
            )
        case "POST", ["causelist", "cnr", "batch"]:
            rows = []
            for cnr in json.loads(request.content)["cnrs"]:
                listing = _listing(cases[cnr]) if cnr in cases else None
                rows.append({"cnr": cnr, "hasCauselist": listing is not None, "nextListing": listing})
            return _ok(rows)
        case "GET", ["causelist", "search"]:
            hits = [_listing(c) for c in cases.values() if _matches(c["courtCaseData"], q)]
            hits = [h for h in hits if h and h["date"] == q.get("date")]
            return _ok({"results": hits, "returnedCount": len(hits), "limit": q.get("limit"), "offset": 0})
    return httpx.Response(404, json={"error": {"code": "NOT_FOUND", "message": "not in synthetic data", "details": []}})


def _ok(data: Any, status: int = 200) -> httpx.Response:
    return httpx.Response(status, json={"data": data, "meta": {"request_id": "synthetic"}})


def _surname_in(name: str, names: list[str]) -> bool:
    """Loose like a provider's fuzzy name match: "Neha Sharma" also finds "N. Sharma"."""
    last = name.lower().split()[-1]
    return any(last in n.lower().split() for n in names)


def _matches(c: Case, q: httpx.QueryParams) -> bool:
    parties = (c.get("petitioners") or []) + (c.get("respondents") or [])
    advocates = (c.get("petitionerAdvocates") or []) + (c.get("respondentAdvocates") or [])
    checks = [
        ("advocates", lambda v: _surname_in(v, advocates)),
        ("advocate", lambda v: _surname_in(v, advocates)),
        ("litigants", lambda v: _surname_in(v, parties)),
        ("judges", lambda v: _surname_in(v, c.get("judges") or [])),
        ("query", lambda v: v.lower() in json.dumps(c).lower()),
    ]
    codes = q.get_list("courtCodes")
    return all(test(q[key]) for key, test in checks if key in q) and (not codes or c["courtComplexCode"] in codes)


def _search_item(case: Case) -> dict[str, Any]:
    keys = (
        "cnr",
        "caseType",
        "caseStatus",
        "filingDate",
        "nextHearingDate",
        "judges",
        "petitioners",
        "respondents",
        "petitionerAdvocates",
        "respondentAdvocates",
        "registrationNumber",
        "decisionDate",
    )
    c = case["courtCaseData"]
    return {k: c.get(k) for k in keys} | {"courtCode": c["courtComplexCode"]}


def _listing(case: Case) -> dict[str, Any] | None:
    c, extra = case["courtCaseData"], case.get("_listing")
    if not (c.get("nextHearingDate") and extra):
        return None
    return {
        "cnr": c["cnr"],
        "date": c["nextHearingDate"],
        "courtNo": extra["courtNo"],
        "listingNo": extra["listingNo"],
        "bench": extra.get("bench"),
        "listType": extra.get("listType", "Daily"),
        "judge": ", ".join(c.get("judges") or []),
        "caseNumber": c.get("registrationNumber"),
        "courtName": c.get("courtName"),
        "courtComplexCode": c.get("courtComplexCode"),
        "party": " v. ".join(((c.get("petitioners") or ["—"])[0], (c.get("respondents") or ["—"])[0])),
    }


def _order_files(case: Case) -> set[str]:
    c = case["courtCaseData"]
    return {o["orderUrl"] for kind in ("judgmentOrders", "interimOrders") for o in c.get(kind) or []}


def _pdf(text: str) -> bytes:
    """A valid one-page PDF showing `text`, so viewers and the order pipeline have a real file locally."""
    stream = f"BT /F1 14 Tf 72 760 Td ({text}) Tj ET".encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> "
        b"/Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream),
    ]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for i, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (i, body)
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)
