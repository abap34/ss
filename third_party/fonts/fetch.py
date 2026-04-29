#!/usr/bin/env python3
"""Download Google Fonts variable TTFs for Noto Sans JP / Mono / Emoji and
materialise per-weight static TTFs that fpdf2 can register directly."""
from __future__ import annotations

import sys
import urllib.request
from pathlib import Path
from typing import Dict, List


HERE = Path(__file__).resolve().parent
GFONTS = "https://raw.githubusercontent.com/google/fonts/main/ofl"

VARIABLE_FONTS: Dict[str, str] = {
    "NotoSansJP[wght].ttf": f"{GFONTS}/notosansjp/NotoSansJP%5Bwght%5D.ttf",
    "NotoSansMono[wdth,wght].ttf": f"{GFONTS}/notosansmono/NotoSansMono%5Bwdth%2Cwght%5D.ttf",
    "NotoEmoji[wght].ttf": f"{GFONTS}/notoemoji/NotoEmoji%5Bwght%5D.ttf",
}

INSTANCES: List[Dict] = [
    {
        "src": "NotoSansJP[wght].ttf",
        "axes": {"wght": 400},
        "out": "NotoSansJP-Regular.ttf",
    },
    {
        "src": "NotoSansJP[wght].ttf",
        "axes": {"wght": 700},
        "out": "NotoSansJP-Bold.ttf",
    },
    {
        "src": "NotoSansJP[wght].ttf",
        "axes": {"wght": 900},
        "out": "NotoSansJP-Black.ttf",
    },
    {
        "src": "NotoSansMono[wdth,wght].ttf",
        "axes": {"wght": 400, "wdth": 100},
        "out": "NotoSansMono-Regular.ttf",
    },
    {
        "src": "NotoSansMono[wdth,wght].ttf",
        "axes": {"wght": 700, "wdth": 100},
        "out": "NotoSansMono-Bold.ttf",
    },
    {
        "src": "NotoEmoji[wght].ttf",
        "axes": {"wght": 400},
        "out": "NotoEmoji-Regular.ttf",
    },
]


def download(name: str, url: str) -> Path:
    out = HERE / "_variable" / name
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists() and out.stat().st_size > 0:
        return out
    print(f"fetch  {name}", file=sys.stderr)
    req = urllib.request.Request(url, headers={"User-Agent": "ss-fonts/1"})
    with urllib.request.urlopen(req) as resp:
        out.write_bytes(resp.read())
    return out


def instance_static(src: Path, axes: Dict[str, float], out: Path) -> None:
    if out.exists() and out.stat().st_size > 0:
        return
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont

    font = TTFont(str(src))
    # updateFontNames rewrites the name table so the produced static font
    # advertises its actual instance (e.g. Regular / Bold) rather than
    # whatever the default instance happened to be (often "Thin"). fpdf2
    # keys fonts off the embedded name, so without this each weight would
    # collide with the others and only one would be embedded in the PDF.
    pinned = instantiateVariableFont(font, axes, updateFontNames=True)
    pinned.save(str(out))
    print(f"build  {out.name} ({axes})", file=sys.stderr)


def fonts_present() -> bool:
    return all((HERE / spec["out"]).exists() for spec in INSTANCES)


def main() -> int:
    if fonts_present():
        return 0
    for name, url in VARIABLE_FONTS.items():
        download(name, url)
    for spec in INSTANCES:
        src = HERE / "_variable" / spec["src"]
        out = HERE / spec["out"]
        instance_static(src, spec["axes"], out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
