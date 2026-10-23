"""Pseudo-locale overflow run (spec §16.4).

Swaps apps/client/l10n/app_en.arb for a copy whose text is 40% longer, regenerates the
localisations, runs the given command in apps/client, then restores the original file.
Flutter reports layout overflow as a test failure, so widget tests run this way catch
strings that will not fit once translated.

    python tools/pseudo_l10n.py flutter test test/widget
"""

import json
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

CLIENT = Path(__file__).resolve().parent.parent / "apps" / "client"
ARB = CLIENT / "l10n" / "app_en.arb"
EXPANSION = 0.4
ARG = re.compile(r"\{\s*\w+\s*(?:,\s*(?:plural|select)\s*,)?")


def pad(run: str) -> str:
    """Add 40% filler, as short breakable words, after a run of literal text."""
    body = run.rstrip()
    if not body.strip():
        return run
    n = math.ceil(len(body.strip()) * EXPANSION)
    return body + (" ~~~~" * n)[: n + 1].rstrip() + run[len(body) :]


def _message(s: str, i: int) -> tuple[str, int]:
    """Literal text and arguments up to an unmatched '}' or the end."""
    out, start = [], i
    while i < len(s) and s[i] != "}":
        if s[i] == "{":
            out.append(pad(s[start:i]))
            arg, i = _argument(s, i)
            out.append(arg)
            start = i
        else:
            i += 1
    out.append(pad(s[start:i]))
    return "".join(out), i


def _argument(s: str, i: int) -> tuple[str, int]:
    """`{name}` is kept; in `{name, plural, key{message} ...}` only the messages grow."""
    head = ARG.match(s, i)
    if not head:
        raise ValueError(f"unsupported ICU syntax at {i}: {s!r}")
    out, i = [head.group()], head.end()
    while s[i] != "}":
        brace = s.index("{", i)
        body, end = _message(s, brace + 1)
        out.append(s[i : brace + 1] + body + "}")
        i = end + 1
    return "".join(out) + "}", i + 1


def expand(message: str) -> str:
    return _message(message, 0)[0]


def run(cmd: list[str]) -> int:
    original = ARB.read_bytes()
    arb = json.loads(original)
    pseudo = {k: v if k.startswith("@") else expand(v) for k, v in arb.items()}
    flutter = shutil.which("flutter") or "flutter"
    try:
        ARB.write_text(json.dumps(pseudo, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        subprocess.run([flutter, "gen-l10n"], cwd=CLIENT, check=True)
        return subprocess.run([shutil.which(cmd[0]) or cmd[0], *cmd[1:]], cwd=CLIENT).returncode
    finally:
        ARB.write_bytes(original)
        subprocess.run([flutter, "gen-l10n"], cwd=CLIENT, check=True)


if __name__ == "__main__":
    for source, want in [
        ("Send code", "Send code ~~~~"),
        ("{selected} of {total}", "{selected} of ~ {total}"),
        ("In {n, plural, =1{1 day} other{{n} days}}", "In ~ {n, plural, =1{1 day ~~} other{{n} days ~~}}"),
    ]:
        assert expand(source) == want, (source, expand(source))
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(run(sys.argv[1:]))
