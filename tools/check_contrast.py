"""WCAG contrast check for design/tokens.json (spec §5.6). Exits 1 on any failure."""

import json
import sys
from pathlib import Path

TOKENS = Path(__file__).resolve().parent.parent / "design" / "tokens.json"


def luminance(hex_color: str) -> float:
    h = hex_color.lstrip("#")
    channels = [int(h[i : i + 2], 16) / 255 for i in (0, 2, 4)]
    lin = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def ratio(a: str, b: str) -> float:
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def checks(tokens: dict) -> list[tuple[str, str, str, str, float]]:
    """Rows of (theme, label, foreground, background, minimum ratio)."""
    rows = []
    for theme in ("light", "dark", "sunlight"):
        c = tokens["color"][theme]
        backgrounds = ("bg", "surface", "surfaceAlt")
        for fg in ("ink", "ink2", "ink3", "primary"):
            for bg in backgrounds:
                rows.append((theme, f"{fg} on {bg}", c[fg], c[bg], 4.5))
        for fg in ("outline", "primaryFill"):
            for bg in backgrounds:
                rows.append((theme, f"{fg} on {bg}", c[fg], c[bg], 3.0))
        rows.append((theme, "onPrimary on primaryFill", c["onPrimary"], c["primaryFill"], 4.5))
        for name, (fg, bg) in tokens["color"]["status"][theme].items():
            rows.append((theme, f"status.{name}", fg, bg, 4.5))
        if theme == "sunlight":
            foregrounds = {k: v for k, v in c.items() if k in ("ink", "ink2", "ink3", "primary", "outline", "line")}
            foregrounds |= {f"status.{k}": v[0] for k, v in tokens["color"]["status"][theme].items()}
            for name, fg in foregrounds.items():
                rows.append((theme, f"{name} on white", fg, "#FFFFFF", 7.0))
    return rows


def main() -> int:
    tokens = json.loads(TOKENS.read_text(encoding="utf-8"))
    failures = 0
    for theme, label, fg, bg, minimum in checks(tokens):
        r = ratio(fg, bg)
        ok = r >= minimum
        failures += not ok
        if not ok or "-v" in sys.argv:
            print(f"{'ok ' if ok else 'FAIL'} {theme:8} {label:32} {r:5.2f} (min {minimum})")
    print(f"contrast: {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    assert round(ratio("#000000", "#FFFFFF"), 2) == 21.0
    assert round(ratio("#FFFFFF", "#FFFFFF"), 2) == 1.0
    sys.exit(main())
