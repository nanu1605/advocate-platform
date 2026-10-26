"""Prompt registry (spec §12.3). `prompts/<task>.md` holds a task's instructions under a `version:` header;
`_system.md` (every task) and `_hindi.md` (Hindi output) are shared. `versions.json` pins the hash of each version,
so a prompt can't change without a new version: `ai_runs` and the summary cache record versions, and evals rerun on
every change.

Untrusted text never enters the instructions. It follows them as numbered `<source>` blocks (documents, matters) and
named `<data>` blocks (a question, a transcript), escaped so it can't close its own tag."""

import hashlib
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from functools import cache
from html import escape
from pathlib import Path
from string import Template
from typing import Literal

from pydantic import BaseModel

DIR = Path(__file__).parent / "prompts"
LANGUAGES = {"en": "English", "hi": "Hindi"}


@dataclass(frozen=True)
class Source:
    """One block of retrieved context. The client numbers sources S1…Sn in the order given."""

    kind: str  # case_doc, order, note, matter…
    text: str
    page: int | None = None
    meta: Mapping[str, str] = field(default_factory=dict)  # more attributes, e.g. the document's title


def tag(element: str, text: str, /, **attrs: object) -> str:
    """`<element a="…">text</element>` with the text and attributes escaped."""
    a = "".join(f' {k}="{escape(str(v))}"' for k, v in attrs.items() if v is not None)
    return f"<{element}{a}>{escape(text, quote=False)}</{element}>"


@dataclass(frozen=True)
class Prompt:
    task: str
    version: str
    instructions: str

    def system(self, language: Literal["hi", "en"], output: type[BaseModel]) -> str:
        parts = [_read("_system.md"), f"Output language: {LANGUAGES[language]}."]
        if language == "hi":
            parts.append(_read("_hindi.md"))
        parts.append("JSON schema of the reply:\n" + json.dumps(output.model_json_schema(), ensure_ascii=False))
        return "\n\n".join(parts)

    def user(
        self,
        params: Mapping[str, str] | None = None,
        sources: Sequence[Source] = (),
        data: Mapping[str, str] | None = None,
    ) -> str:
        """The instructions with `params` filled in (a missing one raises KeyError), then the sources and data."""
        parts = [Template(self.instructions).substitute(params or {})]
        if sources:
            blocks = (
                tag("source", s.text, id=f"S{i}", kind=s.kind, page=s.page, **s.meta) for i, s in enumerate(sources, 1)
            )
            parts.append("<sources>\n" + "\n".join(blocks) + "\n</sources>")
        parts += [tag("data", text, name=name) for name, text in (data or {}).items()]
        return "\n\n".join(parts)


def _read(name: str) -> str:
    return (DIR / name).read_text(encoding="utf-8").strip()


def _split(text: str) -> tuple[str, str]:
    """`---\\nversion: v1\\n---\\nbody` → ("v1", "body")."""
    _, header, body = text.split("---\n", 2)
    [version] = [line.split(":", 1)[1].strip() for line in header.splitlines() if line.startswith("version:")]
    return version, body.strip()


@cache
def load_prompt(task: str) -> Prompt:
    version, body = _split((DIR / f"{task}.md").read_text(encoding="utf-8"))
    return Prompt(task, version, body)


def prompt_hash(task: str) -> str:
    """What `versions.json` pins: the task's file and the shared ones it is sent with."""
    texts = [(DIR / name).read_text(encoding="utf-8") for name in (f"{task}.md", "_system.md", "_hindi.md")]
    return hashlib.sha256("\0".join(texts).encode()).hexdigest()
