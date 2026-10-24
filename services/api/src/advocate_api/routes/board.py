import re
from datetime import date, time, timedelta
from itertools import groupby
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Header
from pydantic import BaseModel, Field
from sqlalchemy import text

from advocate_api.auth import CurrentClaims
from advocate_api.db import CurrentOrg, UserDb, org_context
from advocate_api.ratelimit import limit
from advocate_shared.ist import today_ist

router = APIRouter(prefix="/v1")


class Assignee(BaseModel):
    user_id: UUID
    display_name: str | None


class BoardEntry(BaseModel):
    id: UUID
    matter_id: UUID
    case_type: str | None
    case_number: str | None
    case_year: int | None
    cnr: str | None
    title: str | None
    stage: str | None
    court_no: str | None
    item_no: str | None
    expected_slot: time | None
    clash_group: int | None
    proxy_arranged: bool
    assignee: Assignee | None
    clients: list[str]


class BoardGroup(BaseModel):
    court_id: UUID | None
    court_name: str | None
    court_name_hi: str | None
    short_name: str | None
    short_name_hi: str | None
    entries: list[BoardEntry]


class Board(BaseModel):
    date: date
    groups: list[BoardGroup]
    clash_count: int


def natural(value: str | None) -> tuple:
    """Sort key for court and item numbers ("2" < "10", "S-3" < "S-12"); missing numbers last."""
    if value is None:
        return (1,)
    parts = re.split(r"(\d+)", value.strip().lower())
    return (0, *((0, int(p), "") if p.isdecimal() else (1, 0, p) for p in parts if p))


@router.get("/board/tomorrow")
async def board_tomorrow(db: UserDb, org: CurrentOrg) -> Board:
    """Tomorrow's Board (spec §4.2): worker-built `board_entries`, grouped by court."""
    tomorrow = today_ist() + timedelta(days=1)
    rows = (
        (
            await db.execute(
                text(
                    "select b.id, b.matter_id, m.case_type, m.case_number, m.case_year, m.cnr, m.title, m.stage, "
                    "b.court_no, b.item_no, b.expected_slot, b.clash_group, b.proxy_arranged, b.assignee_id, "
                    "ms.display_name as assignee_name, b.court_id, c.name as court_name, c.name_hi as court_name_hi, "
                    "c.short_name, c.short_name_hi, "
                    "array(select cl.name from public.matter_clients mc "
                    "      join public.clients cl on cl.id = mc.client_id "
                    "      where mc.matter_id = b.matter_id and cl.deleted_at is null order by cl.name) as clients "
                    "from public.board_entries b "
                    "join public.matters m on m.id = b.matter_id "
                    "left join public.courts c on c.id = b.court_id "
                    "left join public.memberships ms on ms.org_id = b.org_id and ms.user_id = b.assignee_id "
                    "where b.org_id = :o and b.board_date = :d and b.is_current and m.deleted_at is null"
                ),
                {"o": org.org_id, "d": tomorrow},
            )
        )
        .mappings()
        .all()
    )
    rows = sorted(
        rows,
        key=lambda r: (
            r["court_name"] is None,
            r["court_name"] or "",
            str(r["court_id"]),
            natural(r["court_no"]),
            natural(r["item_no"]),
        ),
    )
    groups = []
    for _, court_rows in groupby(rows, key=lambda r: r["court_id"]):
        court_rows = list(court_rows)
        first = court_rows[0]
        entries = [
            BoardEntry(
                **{k: r[k] for k in BoardEntry.model_fields if k in r},
                assignee=Assignee(user_id=r["assignee_id"], display_name=r["assignee_name"])
                if r["assignee_id"]
                else None,
            )
            for r in court_rows
        ]
        groups.append(BoardGroup(**{k: first[k] for k in BoardGroup.model_fields if k in first}, entries=entries))
    clashes = {r["clash_group"] for r in rows if r["clash_group"] is not None}
    return Board(date=tomorrow, groups=groups, clash_count=len(clashes))


class FeedbackIn(BaseModel):
    note: str = Field(min_length=1, max_length=4000)
    screen: str | None = Field(None, max_length=200)
    app_version: str | None = Field(None, max_length=50)


class FeedbackOut(BaseModel):
    id: UUID


@router.post("/feedback", status_code=201)
async def send_feedback(
    db: UserDb,
    claims: CurrentClaims,
    body: FeedbackIn,
    x_org_id: Annotated[UUID | None, Header()] = None,
) -> FeedbackOut:
    await limit(f"feedback:{claims['sub']}", 10, 3600)
    if x_org_id is not None:
        await org_context(db, x_org_id)  # NOT_A_MEMBER unless an active member
    row = await db.execute(
        text(
            "insert into public.feedback (org_id, user_id, screen, note, app_version) "
            "values (:o, auth.uid(), :s, :n, :v) returning id"
        ),
        {"o": x_org_id, "s": body.screen, "n": body.note, "v": body.app_version},
    )
    return FeedbackOut(id=row.scalar_one())
