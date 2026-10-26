"""The eval harness and its v1 datasets, without a model: perfect replies built from the expected answers must pass
every gate, and wrong ones must fail it."""

import datetime as dt
import json

import pytest

from legal_ai import evals
from legal_ai.config import load_config
from legal_ai.contracts import Due
from legal_ai.fake import Scripted
from legal_ai.llm import LLMClient

INDIA = {f"BEDROCK_PROFILE_{t}": f"in.test.{t.lower()}" for t in ("FAST", "STANDARD", "DEEP")}


# ---------------------------------------------------------------- the datasets


@pytest.mark.parametrize("name", evals.DATASETS)
def test_items_are_synthetic_with_unique_ids(name):
    items = evals.load(name)
    assert items and all(i["synthetic"] is True and i["language"] in ("hi", "en") for i in items)
    assert len({i["id"] for i in items}) == len(items)


def test_order_items_count_their_due_dates_like_the_app():
    for item in evals.load("orders"):
        order_date = dt.date.fromisoformat(item["order_date"])
        assert item["pages"] and all(p.strip() for p in item["pages"])
        exp = item["expected"]
        assert all(d["match"] for d in exp["directions"])
        for a in exp["actions"]:
            assert a["match"], item["id"]
            due = Due.model_validate(a["due"]).resolve(order_date).isoformat() if a["due"] else None
            assert due == a["due_date"], (item["id"], a)
        if exp["next_date"]:
            assert dt.date.fromisoformat(exp["next_date"]) > order_date


def test_qa_items_cite_pages_that_exist():
    files = evals.casefiles()
    assert all(f["synthetic"] is True for f in files.values())
    for item in evals.load("qa"):
        _, refs = evals.qa_sources(item, files)
        exp = item["expected"]
        if exp["found"]:
            assert exp["match"] and exp["cites"], item["id"]
            assert {tuple(c) for c in exp["cites"]} <= set(refs), item["id"]
        else:
            assert not exp["match"] and not exp["cites"]
    assert sum(not i["expected"]["found"] for i in evals.load("qa")) >= 3


def test_voice_items_name_a_listed_matter():
    for item in evals.load("voice"):
        exp = item["expected"]
        assert item["transcript"].strip() and item["matters"]
        assert exp["matter"] is None or 1 <= exp["matter"] <= len(item["matters"]), item["id"]
        if exp["next_date"]:
            assert dt.date.fromisoformat(exp["next_date"]) > dt.date.fromisoformat(item["today"]), item["id"]


# ---------------------------------------------------------------- the harness


def _cited(text: str, source: str = "S1") -> dict:
    return {"text": text, "sources": [source]}


def perfect(name: str, item: dict, files: dict, wrong: bool = False) -> list[str]:
    """The replies a flawless model would give for `item`, in call order; `wrong` moves every date a day."""

    def shift(d: str | None) -> str | None:
        return (dt.date.fromisoformat(d) + dt.timedelta(days=1)).isoformat() if d and wrong else d

    exp = item["expected"]
    match name:
        case "orders":
            nd = shift(exp["next_date"])
            summary = {
                "title": "Order", "court": None, "order_date": item["order_date"], "judges": [],
                "header_sources": ["S1"], "outcome": None, "gist": _cited("gist"),
                "directions": [_cited(d["match"][0]) for d in exp["directions"]],
                "next_date": {"date": nd, "sources": ["S1"]} if nd else None, "relief": None, "key_reasons": [],
                "authorities_cited_in_document": [], "next_steps_for_us": [],
            }  # fmt: skip
            actions = [
                {
                    "kind": "deadline" if a["due"] else "task",
                    "title": a["match"][0],
                    "due": {"on": shift(a["due_date"])} if wrong and a["due"] else a["due"],
                    "sources": ["S1"],
                }
                for a in exp["actions"]
            ]
            return [json.dumps(summary), json.dumps({"actions": actions})]
        case "qa":
            if not exp["found"] or wrong:
                return [json.dumps({"found": False, "answer": []})]
            _, refs = evals.qa_sources(item, files)
            sid = f"S{refs.index(tuple(exp['cites'][0])) + 1}"
            return [json.dumps({"found": True, "answer": [_cited(exp["match"][0], sid)]})]
        case _:
            m = exp["matter"]
            parse = {
                "matter": f"S{m}" if m else None, "matter_confidence": "high", "next_date": shift(exp["next_date"]),
                "next_date_confidence": "high", "purpose": None, "outcome": None, "tasks": [], "note": None,
            }  # fmt: skip
            return [json.dumps(parse)]


async def recorded(name: str, wrong: bool = False) -> list[dict]:
    items, files = evals.load(name), evals.casefiles()
    replies = [r for item in items for r in perfect(name, item, files, wrong)]
    transport = Scripted(replies)
    client = LLMClient(load_config(env=INDIA), transport)
    records = await evals.produce(client, name, items, concurrency=1)  # one at a time: replies in order
    assert not transport.replies and all(r["status"] == "ok" for r in records)
    return records


@pytest.mark.parametrize("name", evals.DATASETS)
async def test_perfect_replies_pass_every_gate(name):
    m = evals.score(name, evals.load(name), await recorded(name))
    assert evals.failures(m) == []
    assert all(v == 1.0 for k, v in m.items() if k in evals.GATES)
    if name == "voice":
        assert m["voice.matter"] == 1.0


@pytest.mark.parametrize("name", evals.DATASETS)
async def test_wrong_dates_fail_every_gate(name):
    m = evals.score(name, evals.load(name), await recorded(name, wrong=True))
    assert {k for k in evals.GATES if k.startswith(name)} <= set(evals.failures(m))


@pytest.mark.parametrize("cite", ["wrong", "every"])
def test_qa_needs_the_right_pages_and_no_invented_answers(cite):
    """Right words on a wrong page, citing every page, or an answer where the files have none: all wrong."""
    items, files = evals.load("qa"), evals.casefiles()
    records = []
    for item in items:
        exp = item["expected"]
        _, refs = evals.qa_sources(item, files)
        wrong = [f"S{next(i for i, ref in enumerate(refs, 1) if list(ref) not in exp['cites'])}"]
        sources = wrong if cite == "wrong" else [f"S{i}" for i in range(1, len(refs) + 1)]
        text = exp["match"][0] if exp["found"] else "The next date is 12.11.2026."
        out = {"found": True, "answer": [{"text": text, "sources": sources}]}
        records.append({"id": item["id"], "task": "ask_case", "status": "ok", "cost_inr": "0", "output": out})
    m = evals.score("qa", items, records)
    assert m["qa.correct_with_pages"] == 0 and m["qa.citation_precision"] < 0.5


def test_an_unsourced_answer_fails_the_gate():
    assert evals.failures({"qa.answers_without_sources": 1}) == ["qa.answers_without_sources"]
    assert evals.failures({"qa.answers_without_sources": 0, "qa.correct_with_pages": 0.85}) == []


def test_missing_output_counts_as_wrong():
    items = evals.load("voice")
    m = evals.score("voice", items, [])
    assert m["voice.next_date"] == 0 and evals.failures(m) == ["voice.next_date"]


def test_matching_ignores_the_order_of_the_list():
    exp = [{"match": ["interim", "status quo"]}, {"match": ["reply"]}]
    got = [("Respondent No.1 to file reply to the interim application", None), ("Status quo continues", None)]
    assert evals._match(exp, got, dates=False) == evals._match(exp, got[::-1], dates=False) == (2, 2)


def test_nukta_and_case_do_not_count():
    assert evals._hit("हलफ़नामा दाखिल करें", ["हलफनामा"]) and evals._hit("REPLY", ["reply"])


def test_extra_directions_count_against():
    exp = [{"match": ["reply"]}]
    assert evals._match(exp, [("File reply", None)], dates=False) == (1, 1)
    assert evals._match(exp, [("File reply", None), ("Pay costs", None)], dates=False) == (1, 2)
    assert evals._match([{"match": ["reply"], "due_date": "2026-11-09"}], [("reply", dt.date(2026, 11, 10))],
                        dates=True) == (0, 2)  # fmt: skip


async def test_cli_rescores_recorded_outputs_and_reports(tmp_path):
    records = await recorded("voice")
    replies = tmp_path / "runs.jsonl"
    replies.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records), encoding="utf-8")
    report = tmp_path / "report.md"
    assert evals.main(["voice", "--replies", str(replies), "--report", str(report)]) == 0
    text = report.read_text(encoding="utf-8")
    assert "| voice.next_date | 100.0% | ≥ 90% | yes |" in text and "synthetic" in text


def test_cli_refuses_a_live_run_without_ai_live(monkeypatch):
    monkeypatch.delenv("AI_LIVE", raising=False)
    assert evals.main(["voice"]) == 2
