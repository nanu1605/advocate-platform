"""Output contracts of the Phase 2 tasks (spec §4.4, §12.3). Every claim carries the ids of the sources it comes
from. Validated with `context={"source_ids": {...}, "params": {...}}` (LLMClient does), an id the model wasn't
given, or a date before the order or before today, fails and is retried."""

import calendar
import datetime as dt
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, ValidationInfo, model_validator


def _given(v: str, info: ValidationInfo) -> str:
    known = (info.context or {}).get("source_ids")
    if known is not None and v not in known:
        raise ValueError(f"{v} is not one of the sources given")
    return v


SourceId = Annotated[str, Field(pattern=r"^S[1-9][0-9]*$"), AfterValidator(_given)]
Sources = Annotated[list[SourceId], Field(min_length=1)]
Text = Annotated[str, Field(min_length=1)]


def _not_before(day: dt.date | None, param: str, info: ValidationInfo) -> None:
    """A date the model resolved (a year it filled in, "do hafte baad") can't fall before the order or today."""
    floor = ((info.context or {}).get("params") or {}).get(param)
    if day and floor and day < dt.date.fromisoformat(floor):
        raise ValueError(f"{day} is before {param} {floor}: a date without its year is the next such date")


class _Out(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Cited(_Out):
    text: Text
    sources: Sources


class DatedFact(_Out):
    date: dt.date
    sources: Sources


# ---------------------------------------------------------------- order_summary (F07)


class Direction(Cited):
    who: str | None = None  # as the order names them: "the respondents"
    by_when: str | None = None  # as written: "within 4 weeks", "by 12.11.2026"


class OrderSummary(_Out):
    title: Text
    court: str | None
    order_date: dt.date | None
    judges: list[str]
    header_sources: Sources  # where the title, court, date and judges are read
    outcome: Cited | None
    gist: Cited
    directions: list[Direction]
    next_date: DatedFact | None
    relief: Cited | None
    key_reasons: list[Cited]
    authorities_cited_in_document: list[Cited]  # shown "As cited in this order — not verified" (§4.4)
    next_steps_for_us: list[Cited]

    @model_validator(mode="after")
    def _next_after_order(self) -> OrderSummary:
        if self.next_date and self.order_date and self.next_date.date < self.order_date:
            raise ValueError("next_date is before the order's date: a date without its year is the next such date")
        return self


# ---------------------------------------------------------------- order_intel (F13)


class Due(_Out):
    """When a direction is due, as the order states it. The date is counted here, not by the model."""

    on: dt.date | None = None
    within: int | None = Field(default=None, gt=0)
    unit: Literal["days", "weeks", "months"] | None = None

    @model_validator(mode="after")
    def _one_way(self, info: ValidationInfo) -> Due:
        if (self.on is None) == (self.within is None) or (self.within is None) != (self.unit is None):
            raise ValueError("give either `on`, or `within` with `unit`")
        _not_before(self.on, "order_date", info)
        return self

    def resolve(self, order_date: dt.date) -> dt.date:
        """The due date; "within N" counts from the order date. Proposals are marked "verify" (§4.4 F13)."""
        if self.on:
            return self.on
        n = self.within or 0
        match self.unit:
            case "days":
                return order_date + dt.timedelta(days=n)
            case "weeks":
                return order_date + dt.timedelta(weeks=n)
            case _:
                y, m = divmod(order_date.month - 1 + n, 12)
                year, month = order_date.year + y, m + 1
                return order_date.replace(
                    year=year, month=month, day=min(order_date.day, calendar.monthrange(year, month)[1])
                )


class Action(_Out):
    kind: Literal["task", "deadline"]
    title: Text
    due: Due | None
    sources: Sources


class OrderIntel(_Out):
    actions: list[Action]


# ---------------------------------------------------------------- ask_case (F09)


class AskAnswer(_Out):
    found: bool
    answer: list[Cited]  # "I couldn't find this in the case files" is the app's text when found is false

    @model_validator(mode="after")
    def _sourced(self) -> AskAnswer:
        if self.found != bool(self.answer):
            raise ValueError("found is true exactly when answer has points")
        return self


# ---------------------------------------------------------------- brief_me (F29)


class BriefLine(Cited):
    section: Literal["last_time", "pending", "client", "carry"]


class Brief(_Out):
    lines: list[BriefLine] = Field(max_length=8)


# ---------------------------------------------------------------- voice_parse (F14, F22)

Confidence = Literal["high", "low"]


class VoiceTask(_Out):
    title: Text
    due: dt.date | None = None


class VoiceParse(_Out):
    matter: SourceId | None  # one of the candidate matters, given as sources
    matter_confidence: Confidence
    next_date: dt.date | None
    next_date_confidence: Confidence
    purpose: str | None
    outcome: str | None
    tasks: list[VoiceTask]
    note: str | None

    @model_validator(mode="after")
    def _not_past(self, info: ValidationInfo) -> VoiceParse:
        _not_before(self.next_date, "today", info)
        return self


# ---------------------------------------------------------------- client_update (F32)


class ClientUpdate(_Out):
    message: Annotated[str, Field(min_length=1, max_length=1000)]


OUTPUTS: dict[str, type[_Out]] = {
    "order_summary": OrderSummary,
    "order_intel": OrderIntel,
    "ask_case": AskAnswer,
    "brief_me": Brief,
    "voice_parse": VoiceParse,
    "client_update": ClientUpdate,
}
