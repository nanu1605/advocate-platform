"""Eval harness (spec §12.13). Datasets live in `packages/legal_ai/evals/<version>/`; v1 is synthetic, for development
only, and never stands in for the advocate-curated sets at the phase gate.

    AI_LIVE=1 python -m legal_ai.evals orders qa voice --record runs.jsonl --report docs/evals/2026-11-02.md
    python -m legal_ai.evals orders --replies runs.jsonl     # re-score recorded outputs: no model calls

A live run needs AI_LIVE=1 and the Bedrock India profiles in the environment; CI never sets it. Exit code 1 when a
gate fails. Metrics and gates follow the acceptance criteria in spec §4.4."""

import argparse
import asyncio
import datetime as dt
import json
import os
import sys
import unicodedata
from collections.abc import Callable, Iterable, Sequence
from pathlib import Path
from typing import Any

from pydantic import BaseModel

from legal_ai.config import load_config
from legal_ai.contracts import AskAnswer, OrderIntel, OrderSummary, VoiceParse
from legal_ai.llm import AIError, BedrockTransport, LLMClient
from legal_ai.prompts import Source

DATA = Path(__file__).resolve().parents[2] / "evals" / "v1"
DATASETS = ("orders", "qa", "voice")
# metric: minimum (spec §4.4, §17 P2 exit criteria); `qa.answers_without_sources` must be exactly 0.
GATES = {
    "orders.directions_and_next_dates": 0.90,
    "orders.actions_and_deadlines": 0.90,
    "qa.correct_with_pages": 0.85,
    "voice.next_date": 0.90,
}
Item = dict[str, Any]
Record = dict[str, Any]  # {"id", "task", "status", "cost_inr", "output"}


def load(name: str) -> list[Item]:
    return [json.loads(line) for line in (DATA / f"{name}.jsonl").read_text(encoding="utf-8").splitlines() if line]


def casefiles() -> dict[str, Any]:
    return json.loads((DATA / "casefiles.json").read_text(encoding="utf-8"))


def order_sources(item: Item) -> list[Source]:
    return [Source("order", text, page=i) for i, text in enumerate(item["pages"], 1)]


def qa_sources(item: Item, files: dict[str, Any]) -> tuple[list[Source], list[tuple[str, int]]]:
    """Every page of the item's case file (retrieval arrives with task 4), and each source's (document, page)."""
    sources, refs = [], []
    for doc in files[item["casefile"]]["documents"]:
        for page, text in enumerate(doc["pages"], 1):
            sources.append(Source("case_doc", text, page=page, meta={"document": doc["title"]}))
            refs.append((doc["id"], page))
    return sources, refs


def voice_sources(item: Item) -> list[Source]:
    return [Source("matter", label) for label in item["matters"]]


# ---------------------------------------------------------------- running


async def _run(client: LLMClient, item_id: str, task: str, out: type[BaseModel], **kw: Any) -> Record:
    try:
        r = await client.structured(task, out, **kw)
        output, run = r.output.model_dump(mode="json"), r.run
    except AIError as e:
        output, run = None, e.run
    return {"id": item_id, "task": task, "status": run.status, "cost_inr": str(run.cost_inr), "output": output}


async def produce(client: LLMClient, name: str, items: list[Item], concurrency: int = 4) -> list[Record]:
    files = casefiles() if name == "qa" else {}
    gate = asyncio.Semaphore(concurrency)

    async def one(item: Item) -> list[Record]:
        lang = item["language"]
        async with gate:
            match name:
                case "orders":
                    src = order_sources(item)
                    return [
                        await _run(client, item["id"], "order_summary", OrderSummary, language=lang, sources=src),
                        await _run(
                            client,
                            item["id"],
                            "order_intel",
                            OrderIntel,
                            language=lang,
                            sources=src,
                            params={"order_date": item["order_date"]},
                        ),
                    ]
                case "qa":
                    src, _ = qa_sources(item, files)
                    q = {"question": item["question"]}
                    return [await _run(client, item["id"], "ask_case", AskAnswer, language=lang, sources=src, data=q)]
                case _:
                    return [
                        await _run(
                            client,
                            item["id"],
                            "voice_parse",
                            VoiceParse,
                            language=lang,
                            sources=voice_sources(item),
                            params={"today": item["today"]},
                            data={"transcript": item["transcript"]},
                        )
                    ]

    return [r for rs in await asyncio.gather(*(one(i) for i in items)) for r in rs]


# ---------------------------------------------------------------- scoring


def _norm(s: str) -> str:
    """Case, spacing and nukta don't count: हलफ़नामा, हलफनामा and the precomposed फ़ all match."""
    return " ".join(unicodedata.normalize("NFD", s).replace("\u093c", "").casefold().split())


def _hit(text: str, alternatives: Iterable[str]) -> bool:
    t = _norm(text)
    return any(_norm(a) in t for a in alternatives)


def _date(s: str | None) -> dt.date | None:
    return dt.date.fromisoformat(s) if s else None


def _match(expected: list[Item], predicted: Sequence[tuple[str, dt.date | None]], dates: bool) -> tuple[int, int]:
    """(hits, total). An expected entry can pair with a prediction whose text contains one of its `match` phrases
    (and, with `dates`, has its `due_date`); hits is the most pairs possible, each prediction used once, so the
    order of the model's list doesn't matter. Extra predictions count against: total = expected + extras."""
    fits = [
        [
            i
            for i, (text, due) in enumerate(predicted)
            if _hit(text, e["match"]) and (not dates or due == _date(e.get("due_date")))
        ]
        for e in expected
    ]
    paired: dict[int, int] = {}  # prediction -> expected entry

    def pair(e: int, tried: set[int]) -> bool:  # Kuhn's augmenting path
        for i in fits[e]:
            if i not in tried:
                tried.add(i)
                if i not in paired or pair(paired[i], tried):
                    paired[i] = e
                    return True
        return False

    hits = sum(pair(e, set()) for e in range(len(expected)))
    return hits, len(expected) + len(predicted) - hits


def _outputs[T: BaseModel](records: list[Record], task: str, model: type[T]) -> dict[str, T]:
    return {r["id"]: model.model_validate(r["output"]) for r in records if r["task"] == task and r["output"]}


def score(name: str, items: list[Item], records: list[Record]) -> dict[str, float]:
    """Metrics for one dataset; an item without output counts as wrong."""
    m: dict[str, float] = {f"{name}.items": len(items), f"{name}.no_output": sum(not r["output"] for r in records)}
    match name:
        case "orders":
            summaries = _outputs(records, "order_summary", OrderSummary)
            intel = _outputs(records, "order_intel", OrderIntel)
            hits = total = deadline_hits = deadline_total = 0
            for item in items:
                exp, s, a = item["expected"], summaries.get(item["id"]), intel.get(item["id"])
                dirs = [(f"{d.text} {d.who or ''}", None) for d in s.directions] if s else []
                h, t = _match(exp["directions"], dirs, dates=False)
                next_ok = s is not None and (s.next_date.date if s.next_date else None) == _date(exp["next_date"])
                hits, total = hits + h + next_ok, total + t + 1
                order_date = dt.date.fromisoformat(item["order_date"])
                acts = [(x.title, x.due.resolve(order_date) if x.due else None) for x in a.actions] if a else []
                h, t = _match(exp["actions"], acts, dates=True)
                deadline_hits, deadline_total = deadline_hits + h, deadline_total + t
            m["orders.directions_and_next_dates"] = hits / total
            m["orders.actions_and_deadlines"] = deadline_hits / deadline_total if deadline_total else 1.0
        case "qa":
            answers, files = _outputs(records, "ask_case", AskAnswer), casefiles()
            correct = unsourced = cited_all = cited_right = 0
            for item in items:
                exp, a = item["expected"], answers.get(item["id"])
                if a is None:
                    continue
                unsourced += sum(not p.sources for p in a.answer)
                ref = dict(enumerate(qa_sources(item, files)[1], 1))
                cited = {ref.get(int(s[1:]), ("?", 0)) for p in a.answer for s in p.sources}
                right = cited & {tuple(c) for c in exp["cites"]}
                cited_all, cited_right = cited_all + len(cited), cited_right + len(right)
                if not exp["found"]:
                    correct += not a.found
                    continue
                text = " ".join(p.text for p in a.answer)
                correct += a.found and _hit(text, exp["match"]) and bool(cited) and cited == right  # every page right
            m["qa.correct_with_pages"] = correct / len(items)
            m["qa.citation_precision"] = cited_right / cited_all if cited_all else 1.0
            m["qa.answers_without_sources"] = unsourced
        case "voice":
            parses = _outputs(records, "voice_parse", VoiceParse)
            dates = matters = 0
            for item in items:
                exp, p = item["expected"], parses.get(item["id"])
                if p is None:
                    continue
                dates += p.next_date == _date(exp["next_date"])
                matters += p.matter == (f"S{exp['matter']}" if exp["matter"] else None)
            m["voice.next_date"] = dates / len(items)
            m["voice.matter"] = matters / len(items)
    return m


def failures(metrics: dict[str, float]) -> list[str]:
    bad = [k for k, floor in GATES.items() if k in metrics and metrics[k] < floor]
    return bad + [k for k in ("qa.answers_without_sources",) if metrics.get(k)]


def report(metrics: dict[str, float], records: list[Record], when: dt.date) -> str:
    cost = sum(float(r["cost_inr"]) for r in records)
    lines = [
        f"# Evals {when.isoformat()}",
        "",
        f"Datasets: {DATA.name} (synthetic, development only). Runs: {len(records)}, cost ₹{cost:.2f}.",
        "",
        "| Metric | Value | Gate | Pass |",
        "|---|---|---|---|",
    ]
    bad = set(failures(metrics))
    for k, v in metrics.items():
        gate = f"≥ {GATES[k]:.0%}" if k in GATES else "0" if k == "qa.answers_without_sources" else ""
        value = f"{v:.1%}" if k in GATES or k in ("voice.matter", "qa.citation_precision") else f"{v:g}"
        lines.append(f"| {k} | {value} | {gate} | {'no' if k in bad else 'yes' if gate else ''} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None, client_factory: Callable[[], LLMClient] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m legal_ai.evals")
    ap.add_argument("datasets", nargs="*", choices=DATASETS, default=list(DATASETS))
    ap.add_argument("--replies", type=Path, help="score recorded outputs instead of calling the model")
    ap.add_argument("--record", type=Path, help="write each run's output here (JSONL)")
    ap.add_argument("--report", type=Path, help="write the results table here (docs/evals/YYYY-MM-DD.md)")
    args = ap.parse_args(argv)

    if args.replies:
        recorded = [json.loads(line) for line in args.replies.read_text(encoding="utf-8").splitlines() if line]
    elif client_factory is None and os.environ.get("AI_LIVE") != "1":
        print("A live eval run calls Bedrock: set AI_LIVE=1 (never in CI), or score recorded outputs with --replies.")
        return 2
    else:
        client = client_factory() if client_factory else _live_client()
        recorded = []
        for name in args.datasets:
            recorded += asyncio.run(produce(client, name, load(name)))
        if args.record:
            args.record.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in recorded), "utf-8")

    metrics: dict[str, float] = {}
    for name in args.datasets:
        items = load(name)
        ids = {i["id"] for i in items}
        metrics |= score(name, items, [r for r in recorded if r["id"] in ids])
    text = report(metrics, recorded, dt.date.today())
    if args.report:
        args.report.write_text(text, "utf-8")
    if reconfigure := getattr(sys.stdout, "reconfigure", None):
        reconfigure(encoding="utf-8")  # ₹ and ≥ on a Windows console or redirect
    print(text)
    return 1 if failures(metrics) else 0


def _live_client() -> LLMClient:
    cfg = load_config()
    return LLMClient(cfg, BedrockTransport(cfg.providers.bedrock_india))


if __name__ == "__main__":
    sys.exit(main())
