"""The four screens' backdrop (0.8.0, Mark: "a background image under it for formatting"): a 1920x1080 picture in the
app's own dark colours with the raven mark (assets/brand/mark.png, from make_brand.py) faint in the lower right.
The "4 / OK" mark in the middle is drawn by the app, not baked in.

    python tools/make_backdrop.py

Writes assets/brand/backdrop.png (needs Pillow).
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
MARK = ROOT / "assets" / "brand" / "mark.png"
OUT = ROOT / "assets" / "brand" / "backdrop.png"

W, H = 1920, 1080
TOP = (0x10, 0x11, 0x14)  # tvBackground
BOTTOM = (0x1C, 0x1F, 0x25)  # tvSurface


def main() -> None:
    img = Image.new("RGB", (W, H), TOP)
    draw = ImageDraw.Draw(img)
    # a soft vertical gradient, a little lighter towards the bottom
    for y in range(H):
        t = y / (H - 1)
        colour = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
        draw.line([(0, y), (W, y)], fill=colour)
    # the raven mark, large and faint, in the lower right
    mark = Image.open(MARK).convert("RGBA")
    size = 720
    mark = mark.resize((size, size), Image.LANCZOS)
    alpha = mark.getchannel("A").point(lambda a: int(a * 0.16))
    mark.putalpha(alpha)
    img = img.convert("RGBA")
    img.alpha_composite(mark, (W - size - 80, H - size - 20))
    img.convert("RGB").save(OUT, optimize=True)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
