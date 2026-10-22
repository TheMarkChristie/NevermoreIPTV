"""Nevermore IPTV's icon and TV banner: a raven perched on a TV showing a play button (Poe's raven, "perched upon a
bust of Pallas just above my chamber door"), drawn as SVG and rendered to every size Android asks for.

    python tools/make_brand.py

Writes brand/*.svg (for review), the launcher icons (legacy and adaptive, mdpi to xxxhdpi), the 320x180 TV banner
(xhdpi and xxhdpi) and assets/brand/mark.png (the start screen). Needs Pillow and Google Chrome (headless Chrome draws
the SVG; there is no cairo on this PC for cairosvg).
"""
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from PIL import Image

CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android" / "app" / "src" / "main" / "res"
BRAND = ROOT / "brand"

# the mark on a 512 canvas: the TV (silver frame, dark screen, play button) and the raven on its top edge, facing left
MARK = """
  <defs>
    <linearGradient id="frame" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#E6EBF2"/><stop offset="1" stop-color="#A7B1BF"/>
    </linearGradient>
    <radialGradient id="moon" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#6B7790" stop-opacity="0.85"/>
      <stop offset="0.7" stop-color="#4A5468" stop-opacity="0.35"/>
      <stop offset="1" stop-color="#4A5468" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <g transform="translate(-19 11)">
    <circle cx="292" cy="142" r="132" fill="url(#moon)"/>
    <rect x="92" y="214" width="328" height="196" rx="30" fill="url(#frame)"/>
    <rect x="108" y="230" width="296" height="164" rx="16" fill="#0F1217"/>
    <path d="M226 274 L226 350 L296 312 Z" fill="#A9BEDA" stroke="#A9BEDA" stroke-width="18" stroke-linejoin="round"/>
    <path fill="#06070A" d="
      M186 118 L222 104 C228 101 233 98 238 96
      C254 80 284 80 296 98
      C310 108 334 112 356 122
      C392 136 420 162 438 198
      L458 236 L430 226
      C404 214 378 208 350 208
      C326 210 300 204 284 194
      C264 180 252 160 250 140
      L242 146 L246 136 L236 138 L240 129
      C230 124 214 122 200 122 Z"/>
    <rect x="300" y="196" width="7" height="20" rx="3" fill="#06070A"/>
    <rect x="320" y="198" width="7" height="18" rx="3" fill="#06070A"/>
    <rect x="290" y="211" width="22" height="7" rx="3.5" fill="#06070A"/>
    <rect x="311" y="211" width="22" height="7" rx="3.5" fill="#06070A"/>
    <path d="M302 130 C338 148 374 176 410 212" fill="none" stroke="#2F3B52" stroke-width="7" stroke-linecap="round"/>
    <circle cx="262" cy="104" r="5.5" fill="#C5D3E6"/>
  </g>
"""

BACKGROUND = """
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3B4353"/><stop offset="1" stop-color="#161920"/>
    </linearGradient>
  </defs>
"""


def icon_svg() -> str:
    """The legacy launcher icon: the mark on the rounded slate square."""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">{BACKGROUND}'
            f'<rect width="512" height="512" rx="112" fill="url(#bg)"/>{MARK}</svg>')


def foreground_svg() -> str:
    """The adaptive icon's front layer: the mark alone, shrunk into the 66% circle every launcher mask keeps."""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">'
            f'<g transform="translate(256 256) scale(0.72) translate(-256 -256)">{MARK}</g></svg>')


def banner_svg() -> str:
    """The Google TV app row's 320x180 banner: the mark on the left, the name on the right."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 180">
  <defs>
    <linearGradient id="bbg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#343C4B"/><stop offset="1" stop-color="#121419"/>
    </linearGradient>
  </defs>
  <rect width="320" height="180" fill="url(#bbg)"/>
  <g transform="translate(6 16) scale(0.29)">{MARK}</g>
  <text x="156" y="94" font-family="Segoe UI" font-weight="600" font-size="31" fill="#FFFFFF">Nevermore</text>
  <text x="158" y="120" font-family="Segoe UI" font-weight="600" font-size="15" letter-spacing="5" fill="#A9BEDA">IPTV</text>
</svg>"""


def render(svg: str, width: int, height: int) -> Image.Image:
    """Headless Chrome draws the SVG four times larger on a transparent page; Pillow scales it down (smoother edges
    at the small sizes)."""
    big_w, big_h = width * 4, height * 4
    sized = svg.replace("<svg ", f'<svg width="{big_w}" height="{big_h}" ', 1)
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "page.html"
        shot = Path(tmp) / "shot.png"
        page.write_text(f'<!doctype html><html><body style="margin:0;background:transparent">{sized}</body></html>',
                        encoding="utf-8")
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--default-background-color=00000000", f"--window-size={big_w},{big_h}",
                        f"--screenshot={shot}", page.as_uri()], check=True, capture_output=True, timeout=60)
        image = Image.open(shot).convert("RGBA").crop((0, 0, big_w, big_h))
        return image.resize((width, height), Image.LANCZOS)


def main() -> None:
    BRAND.mkdir(exist_ok=True)
    (BRAND / "icon.svg").write_text(icon_svg(), encoding="utf-8")
    (BRAND / "icon-foreground.svg").write_text(foreground_svg(), encoding="utf-8")
    (BRAND / "banner.svg").write_text(banner_svg(), encoding="utf-8")

    for bucket, scale in {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}.items():
        folder = RES / f"mipmap-{bucket}"
        folder.mkdir(exist_ok=True)
        render(icon_svg(), round(48 * scale), round(48 * scale)).save(folder / "ic_launcher.png")
        render(foreground_svg(), round(108 * scale), round(108 * scale)).save(folder / "ic_launcher_foreground.png")

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n', encoding="utf-8")
    values = RES / "values"
    (values / "colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <color name="ic_launcher_background">#262C37</color>\n</resources>\n', encoding="utf-8")

    for bucket, scale in {"xhdpi": 1, "xxhdpi": 1.5}.items():
        folder = RES / f"drawable-{bucket}"
        folder.mkdir(exist_ok=True)
        render(banner_svg(), round(320 * scale), round(180 * scale)).convert("RGB").save(folder / "banner.png")

    assets = ROOT / "assets" / "brand"
    assets.mkdir(parents=True, exist_ok=True)
    render(icon_svg(), 256, 256).save(assets / "mark.png")
    render(icon_svg(), 1024, 1024).save(BRAND / "icon-1024.png")
    render(banner_svg(), 640, 360).save(BRAND / "banner-640.png")
    print("brand written")


if __name__ == "__main__":
    main()
