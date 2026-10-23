"""Draw the placeholder app icon (spec §2.3): ink rounded square, first letter of appName in paper-white,
short indigo bar underneath. Writes brand/icon-1024.png and brand/logo.svg."""

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024
INK, PAPER, INDIGO = "#16181D", "#FAF8F3", "#605AE6"


def main() -> None:
    brand = json.loads((ROOT / "brand/brand.json").read_text(encoding="utf-8"))
    letter = brand["appName"][0].upper()
    font = ImageFont.truetype(str(ROOT / "apps/client/assets/fonts/Mukta/Mukta-SemiBold.ttf"), 620)

    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=224, fill=INK)
    d.text((SIZE / 2, SIZE * 0.47), letter, font=font, fill=PAPER, anchor="mm")
    d.rounded_rectangle((SIZE * 0.36, SIZE * 0.76, SIZE * 0.64, SIZE * 0.80), radius=20, fill=INDIGO)
    img.save(ROOT / "brand/icon-1024.png")

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
        f'<rect width="1024" height="1024" rx="224" fill="{INK}"/>'
        f'<text x="512" y="560" text-anchor="middle" dominant-baseline="middle" font-family="Mukta" '
        f'font-weight="600" font-size="620" fill="{PAPER}">{letter}</text>'
        f'<rect x="369" y="778" width="286" height="41" rx="20" fill="{INDIGO}"/></svg>\n'
    )
    (ROOT / "brand/logo.svg").write_text(svg, encoding="utf-8")
    print("wrote brand/icon-1024.png, brand/logo.svg")


if __name__ == "__main__":
    main()
