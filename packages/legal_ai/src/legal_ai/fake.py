"""Stand-ins for Bedrock while AI_LIVE=0 (local runs, CI): no request leaves the machine.

`local_transport` answers every Phase 2 task with a valid, plainly labelled placeholder, so the app's flows run end
to end without a model. `Scripted` replays given replies and records the requests, for tests."""

import json
import re
from collections.abc import Iterable
from typing import Any

OFF = "AI is off on this machine (AI_LIVE=0): this is placeholder text."


def response(text: str, *, stop: str = "end_turn", input_tokens: int = 1000, output_tokens: int = 200) -> dict:
    """A Converse response carrying `text` (thinking tokens are counted in output_tokens, as Bedrock bills them)."""
    return {
        "output": {"message": {"role": "assistant", "content": [{"text": text}]}},
        "stopReason": stop,
        "usage": {
            "inputTokens": input_tokens,
            "outputTokens": output_tokens,
            "totalTokens": input_tokens + output_tokens,
        },
        "metrics": {"latencyMs": 1},
    }


def local_transport(task: str, request: dict[str, Any]) -> dict:
    sent = json.dumps(request, ensure_ascii=False)
    ids = re.findall(r'<source id="(S\d+)"', request["messages"][0]["content"][0]["text"])
    first = ids[0] if ids else "S1"  # a task that needs a source fails without one, as it would live
    cited = {"text": OFF, "sources": [first]}
    replies: dict[str, Any] = {
        "order_summary": {
            "title": "Order",
            "court": None,
            "order_date": None,
            "judges": [],
            "header_sources": [first],
            "outcome": None,
            "gist": cited,
            "directions": [],
            "next_date": None,
            "relief": None,
            "key_reasons": [],
            "authorities_cited_in_document": [],
            "next_steps_for_us": [],
        },
        "order_intel": {"actions": []},
        "ask_case": {"found": False, "answer": []},
        "brief_me": {"lines": [{"section": "last_time", **cited}] if ids else []},
        "voice_parse": {
            "matter": None,
            "matter_confidence": "low",
            "next_date": None,
            "next_date_confidence": "low",
            "purpose": None,
            "outcome": None,
            "tasks": [],
            "note": OFF,
        },
        "client_update": {"message": OFF},
    }
    text = json.dumps(replies[task], ensure_ascii=False)
    return response(text, input_tokens=len(sent) // 4, output_tokens=len(text) // 4)


class Scripted:
    """Replies in order: a str is the model's text, a dict a whole Converse response, an exception is raised."""

    def __init__(self, replies: Iterable[str | dict | Exception]):
        self.replies = list(replies)
        self.requests: list[tuple[str, dict[str, Any]]] = []

    def __call__(self, task: str, request: dict[str, Any]) -> dict:
        self.requests.append((task, json.loads(json.dumps(request))))  # a copy: the client keeps appending
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply if isinstance(reply, dict) else response(reply)
