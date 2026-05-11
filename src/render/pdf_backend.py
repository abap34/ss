#!/usr/bin/env python3
"""
PDF backend.

The dump JSON emitted by the Zig core describes nodes in PDF-native (bottom-left)
coordinates with embedded markdown / inline runs already laid out by the IR.
This module turns that document into a PDF using ``fpdf2`` for text, code, and
chrome, and overlays vector PDFs (math, embedded assets) via ``pypdf`` after the
base pages are written.

fpdf2 is responsible for Unicode coverage: Noto Sans JP / Noto Sans Mono / Noto
Emoji are registered as text families and ``set_fallback_fonts`` handles
codepoint fallback so CJK and emoji glyphs resolve without manual per-character
splitting.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from fpdf import FPDF
from fpdf.image_parsing import SETTINGS as FPDF_IMAGE_SETTINGS
from PIL import Image
from pypdf import PdfReader, PdfWriter, Transformation

PAGE_WIDTH = 1280.0
PAGE_HEIGHT = 720.0
REPO_ROOT = Path(__file__).resolve().parents[2]
FONT_DIR = REPO_ROOT / "third_party" / "fonts"
MATH_RENDER_VERSION = "v3"
LATEX_DEFAULT_FONT_SIZE_PT = 10.0
DISPLAY_MATH_FONT_SCALE = 1.1
HIGHLIGHT_RENDER_VERSION = "v1"
FA_RENDER_VERSION = "v1"
SVG_ASSET_RENDER_VERSION = "v1"
INCREMENTAL_RENDER_VERSION = "page-cache-v1"

CACHE_ROOT = Path(".ss-cache")
MATH_CACHE_DIRNAME = "math"
HIGHLIGHT_CACHE_DIRNAME = "highlight"
ICON_CACHE_DIRNAME = "icons"
SVG_ASSET_CACHE_DIRNAME = "svg-assets"
RENDER_CACHE_DIRNAME = "render"
PAGE_CACHE_DIRNAME = "pages"
DOCUMENT_CACHE_DIRNAME = "documents"
MANIFEST_CACHE_DIRNAME = "manifests"

DEFAULT_CACHE_MAX_BYTES = 256 * 1024 * 1024
CACHE_MAX_BYTES_ENV = "SS_CACHE_MAX_BYTES"
CACHE_PRUNE_TARGET_RATIO = 0.80

TMP_FULL_BASE_LABEL = "full-base"
TMP_PAGE_BASE_LABEL = "page-base"
TMP_PAGE_FINAL_LABEL = "page-final"
PDF_SUFFIX = ".pdf"
INTERNAL_LINK_PREFIX = "#"

# fpdf2 recompresses PNG image streams when embedding them. Lowering the zlib
# level keeps the compression lossless while making iterative renders much
# cheaper on image-heavy decks.
FPDF_IMAGE_SETTINGS.compression_level = 1

# Canonical fpdf2 family + style for each render-policy font name.
FONT_ALIAS: Dict[str, Tuple[str, str]] = {
    "Helvetica": ("body", ""),
    "Helvetica-Bold": ("body", "B"),
    "Helvetica-Oblique": ("body", ""),
    "Helvetica-BoldOblique": ("body", "B"),
    "Times-Roman": ("body", ""),
    "Times-Bold": ("body", "B"),
    "Times-Italic": ("body", ""),
    "Times-BoldItalic": ("body", "B"),
    "Courier": ("mono", ""),
    "Courier-Bold": ("mono", "B"),
    "Courier-Oblique": ("mono", ""),
    "Courier-BoldOblique": ("mono", "B"),
}

Color = Tuple[float, float, float]


@dataclass
class Overlay:
    """A vector PDF to merge over the base page in PDF-native coordinates."""

    pdf_path: str
    x: float
    y: float
    width: float
    height: float


@dataclass(frozen=True)
class RuntimeCaches:
    math_dir: Path
    highlight_dir: Path
    icon_dir: Path
    svg_asset_dir: Path
    render_dir: Path
    page_dir: Path
    document_dir: Path
    manifest_dir: Path

    @classmethod
    def create(cls) -> "RuntimeCaches":
        render_dir = CACHE_ROOT / RENDER_CACHE_DIRNAME
        caches = cls(
            math_dir=CACHE_ROOT / MATH_CACHE_DIRNAME,
            highlight_dir=CACHE_ROOT / HIGHLIGHT_CACHE_DIRNAME,
            icon_dir=CACHE_ROOT / ICON_CACHE_DIRNAME,
            svg_asset_dir=CACHE_ROOT / SVG_ASSET_CACHE_DIRNAME,
            render_dir=render_dir,
            page_dir=render_dir / PAGE_CACHE_DIRNAME,
            document_dir=render_dir / DOCUMENT_CACHE_DIRNAME,
            manifest_dir=render_dir / MANIFEST_CACHE_DIRNAME,
        )
        for path in (caches.math_dir, caches.highlight_dir, caches.icon_dir, caches.svg_asset_dir, caches.render_dir):
            path.mkdir(parents=True, exist_ok=True)
        return caches

    def prune(self) -> None:
        max_bytes = configured_cache_max_bytes()
        if max_bytes is None:
            return
        prune_cache_entries(self.managed_entry_paths(), max_bytes)

    def managed_entry_paths(self) -> List[Path]:
        entries: List[Path] = []
        for directory in (self.math_dir, self.icon_dir, self.svg_asset_dir):
            entries.extend(cache_dir_children(directory))
        for directory in (self.highlight_dir, self.page_dir, self.document_dir, self.manifest_dir):
            entries.extend(cache_file_children(directory))
        return entries

    def ensure_page_cache(self) -> None:
        self.page_dir.mkdir(parents=True, exist_ok=True)
        self.document_dir.mkdir(parents=True, exist_ok=True)
        self.manifest_dir.mkdir(parents=True, exist_ok=True)

    def temp_pdf(self, label: str, identity: str) -> Path:
        pid = os.getpid()
        nonce = hashlib.sha256(f"{label}:{identity}:{pid}".encode("utf-8")).hexdigest()[:12]
        return self.render_dir / f"tmp-{label}-{pid}-{nonce}{PDF_SUFFIX}"


@dataclass(frozen=True)
class IncrementalRenderStats:
    rendered: int
    reused: int
    total: int

    def message(self) -> str:
        return f"pdf backend: incremental render reused {self.reused}/{self.total} page(s), rendered {self.rendered}"


@dataclass(frozen=True)
class CachedPage:
    index: int
    page_id: int
    name: Optional[str]
    digest: str
    pdf_path: Path

    def manifest_entry(self) -> dict:
        return {
            "index": self.index,
            "page_id": self.page_id,
            "name": self.name,
            "hash": self.digest,
            "pdf": str(self.pdf_path),
        }


@dataclass(frozen=True)
class CacheEntry:
    path: Path
    size: int
    mtime: float


def configured_cache_max_bytes() -> Optional[int]:
    raw = os.environ.get(CACHE_MAX_BYTES_ENV)
    if raw is None or raw.strip() == "":
        return DEFAULT_CACHE_MAX_BYTES

    value = raw.strip().lower()
    if value in ("off", "none", "false", "no", "unlimited"):
        return None

    match = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([kmgt]?i?b?|b)?", value)
    if match is None:
        print(
            f"pdf backend: ignoring invalid {CACHE_MAX_BYTES_ENV}={raw!r}; using {DEFAULT_CACHE_MAX_BYTES} bytes",
            file=sys.stderr,
        )
        return DEFAULT_CACHE_MAX_BYTES

    number = float(match.group(1))
    suffix = (match.group(2) or "b").lower()
    scale = 1
    if suffix.startswith("k"):
        scale = 1024
    elif suffix.startswith("m"):
        scale = 1024 * 1024
    elif suffix.startswith("g"):
        scale = 1024 * 1024 * 1024
    elif suffix.startswith("t"):
        scale = 1024 * 1024 * 1024 * 1024
    return max(0, int(number * scale))


def cache_dir_children(directory: Path) -> List[Path]:
    try:
        return [path for path in directory.iterdir() if path.is_dir()]
    except OSError:
        return []


def cache_file_children(directory: Path) -> List[Path]:
    try:
        return [path for path in directory.iterdir() if path.is_file() and not path.name.startswith("tmp-")]
    except OSError:
        return []


def cache_entry(path: Path) -> Optional[CacheEntry]:
    try:
        stat = path.stat()
    except OSError:
        return None

    if path.is_file():
        return CacheEntry(path=path, size=stat.st_size, mtime=stat.st_mtime)

    size = 0
    mtime = stat.st_mtime
    for root, _dirs, files in os.walk(path):
        root_path = Path(root)
        try:
            root_stat = root_path.stat()
            mtime = max(mtime, root_stat.st_mtime)
        except OSError:
            pass
        for name in files:
            child = root_path / name
            try:
                child_stat = child.stat()
            except OSError:
                continue
            size += child_stat.st_size
            mtime = max(mtime, child_stat.st_mtime)
    return CacheEntry(path=path, size=size, mtime=mtime)


def touch_cache_entry(path: Path) -> None:
    try:
        os.utime(path, None)
    except OSError:
        pass


def prune_cache_entries(paths: List[Path], max_bytes: int) -> None:
    entries = [entry for path in paths if (entry := cache_entry(path)) is not None]
    total = sum(entry.size for entry in entries)
    if total <= max_bytes:
        return

    target = int(max_bytes * CACHE_PRUNE_TARGET_RATIO)
    for entry in sorted(entries, key=lambda item: (item.mtime, str(item.path))):
        if total <= target:
            break
        try:
            if entry.path.is_dir():
                shutil.rmtree(entry.path)
            else:
                entry.path.unlink()
        except OSError:
            continue
        total -= entry.size


@dataclass(frozen=True)
class TextPaintSpec:
    font_name: str
    bold_font_name: str
    italic_font_name: str
    code_font_name: str
    font_size: float
    color: Color
    line_height: float
    link_color: Color
    link_underline_width: float
    link_underline_offset: float
    inline_math_height_factor: float
    inline_math_spacing: float
    markdown_block_gap: float
    markdown_list_inset: float
    markdown_list_indent: float
    markdown_code_font_size: float
    markdown_code_line_height: float
    markdown_code_pad_x: float
    markdown_code_pad_y: float
    markdown_code_fill: Optional[Color]
    markdown_code_stroke: Optional[Color]
    markdown_code_line_width: float
    markdown_code_radius: float
    cjk_bold_passes: int
    cjk_bold_dx: float
    math_latex_packages: List[str]


@dataclass(frozen=True)
class HighlighterSpec:
    language: str
    script_path: Path

    def argv(self) -> List[str]:
        return [sys.executable, str(self.script_path), "--language", self.language]


@dataclass(frozen=True)
class MathRenderJob:
    kind: str
    tex_body: str
    color: Optional[Color]
    packages: Tuple[str, ...]
    digest: str
    work_dir: Path
    tex_path: Path
    pdf_path: Path


CODE_HIGHLIGHTERS: Dict[str, HighlighterSpec] = {
    "python": HighlighterSpec(
        language="python",
        script_path=REPO_ROOT / "stdlib" / "highlighters" / "python_keywords.py",
    ),
}

DEFAULT_CODE_KEYWORD = (44.0 / 255.0, 88.0 / 255.0, 201.0 / 255.0)
DEFAULT_CODE_COMMENT = (78.0 / 255.0, 138.0 / 255.0, 92.0 / 255.0)
DEFAULT_CODE_STRING = (178.0 / 255.0, 65.0 / 255.0, 55.0 / 255.0)


# fpdf2 emits a warning per glyph that is not covered by any registered font.
# Surface them once at the end of a run so a missing emoji or rare CJK glyph is
# still visible without drowning the console.
_glyph_warnings: List[str] = []
_renderer_fingerprint_cache: Optional[str] = None


class _GlyphWarningFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        message = record.getMessage()
        if "is missing the following glyphs" in message:
            _glyph_warnings.append(message)
            return False
        return True


def _install_glyph_warning_filter() -> None:
    logging.getLogger("fpdf").addFilter(_GlyphWarningFilter())


def main(argv: List[str]) -> int:
    if len(argv) != 4:
        print("usage: pdf_backend.py <input.json> <output.pdf> <asset-base-dir>", file=sys.stderr)
        return 2

    input_json, output_pdf, asset_base_dir = argv[1], argv[2], argv[3]

    ensure_fonts_present()
    _install_glyph_warning_filter()

    with open(input_json, "r", encoding="utf-8") as f:
        doc = json.load(f)

    caches = RuntimeCaches.create()
    caches.prune()

    if supports_incremental_render(doc):
        stats = IncrementalPageRenderer(doc, output_pdf, asset_base_dir, caches).render()
        print(stats.message(), file=sys.stderr)
    else:
        render_full_document(doc, output_pdf, asset_base_dir, caches)
    caches.prune()

    if _glyph_warnings:
        unique = sorted(set(_glyph_warnings))
        print(f"pdf backend: {len(unique)} glyph fallback warning(s)", file=sys.stderr)
        for warning in unique[:5]:
            print(f"  {warning}", file=sys.stderr)
        if len(unique) > 5:
            print(f"  ... and {len(unique) - 5} more", file=sys.stderr)
    return 0


def ensure_fonts_present() -> None:
    needed = [
        "NotoSansJP-Regular.ttf",
        "NotoSansJP-Bold.ttf",
        "NotoSansJP-Black.ttf",
        "NotoSansMono-Regular.ttf",
        "NotoSansMono-Bold.ttf",
        "NotoEmoji-Regular.ttf",
    ]
    if all((FONT_DIR / name).exists() for name in needed):
        return
    fetch_script = FONT_DIR / "fetch.py"
    subprocess.run([sys.executable, str(fetch_script)], check=True)


def render_full_document(doc: dict, output_pdf: str, asset_base_dir: str, caches: RuntimeCaches) -> None:
    base_pdf = caches.temp_pdf(TMP_FULL_BASE_LABEL, output_pdf)
    try:
        prewarm_math_cache_for_doc(doc, caches.math_dir)
        renderer = Renderer(asset_base_dir, caches.math_dir, caches.highlight_dir, caches.icon_dir, caches.svg_asset_dir)
        overlays_by_page = renderer.render(doc, str(base_pdf))
        merge_overlays(str(base_pdf), output_pdf, overlays_by_page)
    finally:
        base_pdf.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Renderer


class Renderer:
    def __init__(self, asset_base_dir: str, math_cache_dir: Path, highlight_cache_dir: Path, icon_cache_dir: Path, svg_asset_cache_dir: Path) -> None:
        self.asset_base_dir = asset_base_dir
        self.math_cache_dir = math_cache_dir
        self.highlight_cache_dir = highlight_cache_dir
        self.icon_cache_dir = icon_cache_dir
        self.svg_asset_cache_dir = svg_asset_cache_dir
        self.pdf = FPDF(unit="pt", format=(PAGE_WIDTH, PAGE_HEIGHT))
        self.pdf.set_auto_page_break(auto=False)
        self.pdf.set_margins(0, 0, 0)
        self.pdf.c_margin = 0
        self._internal_links: Dict[str, int] = {}
        self._current_page_index = 0
        self._fontkey_to_family_style: Dict[str, Tuple[str, str]] = {}
        self._ensure_font("body", "")
        self.pdf.set_fallback_fonts(["body"], exact_match=False)

    def _ensure_font(self, family: str, style: str) -> None:
        key = self._font_key(family, style)
        if key in self.pdf.fonts:
            return
        self.pdf.add_font(family, style, str(self._font_path(family, style)))
        self._fontkey_to_family_style[key] = (family, style)
        if family == "emoji":
            self.pdf.set_fallback_fonts(["body", "emoji"], exact_match=False)

    def _font_path(self, family: str, style: str) -> Path:
        body_reg = FONT_DIR / "NotoSansJP-Regular.ttf"
        body_bold = FONT_DIR / "NotoSansJP-Bold.ttf"
        mono_reg = FONT_DIR / "NotoSansMono-Regular.ttf"
        mono_bold = FONT_DIR / "NotoSansMono-Bold.ttf"
        emoji = FONT_DIR / "NotoEmoji-Regular.ttf"
        if family == "body":
            return body_bold if "B" in style else body_reg
        if family == "mono":
            return mono_bold if "B" in style else mono_reg
        if family == "emoji":
            return emoji
        raise RuntimeError(f"unknown font family: {family}")

    # -- font run resolution (fpdf2's pdf.text() does not honour set_fallback_fonts;
    #    only cell()/write() do. We split each run into per-font segments so we can
    #    keep using pdf.text() for precise positioning while still getting CJK +
    #    emoji coverage from the registered fallback chain.) --

    def _resolve_font_for_char(self, char: str, family: str, style: str) -> Tuple[str, str]:
        self._ensure_font(family, style)
        primary_key = self._font_key(family, style)
        primary = self.pdf.fonts.get(primary_key)
        if primary is not None and ord(char) in primary.cmap:
            return family, style
        self._ensure_font("emoji", "")
        fallback_id = self.pdf.get_fallback_font(char, style)
        if fallback_id is not None:
            return self._family_style_of(fallback_id)
        return family, style

    def _font_key(self, family: str, style: str) -> str:
        return family + style

    def _family_style_of(self, font_id: str) -> Tuple[str, str]:
        return self._fontkey_to_family_style.get(font_id, ("body", ""))

    def _split_runs(self, text: str, family: str, style: str) -> List[Tuple[str, str, str]]:
        """Split ``text`` into ``(family, style, segment)`` runs so each segment can
        be drawn with a font that actually has its glyphs."""
        if not text:
            return []
        runs: List[Tuple[str, str, str]] = []
        cur_family, cur_style = family, style
        cur_chars: List[str] = []
        for ch in text:
            res_family, res_style = self._resolve_font_for_char(ch, family, style)
            if cur_chars and (res_family, res_style) != (cur_family, cur_style):
                runs.append((cur_family, cur_style, "".join(cur_chars)))
                cur_chars = []
            cur_family, cur_style = res_family, res_style
            cur_chars.append(ch)
        if cur_chars:
            runs.append((cur_family, cur_style, "".join(cur_chars)))
        return runs

    def _draw_text_with_fallback(
        self,
        x: float,
        baseline_tl: float,
        text: str,
        family: str,
        style: str,
        size: float,
        cjk_bold_passes: int = 1,
        cjk_bold_dx: float = 0.0,
    ) -> float:
        """Like ``self.pdf.text()`` but switches fonts per glyph so missing
        codepoints fall back to the registered chain. Returns the cursor x
        advance (sum of run widths)."""
        cursor = x
        for run_family, run_style, segment in self._split_runs(text, family, style):
            self._ensure_font(run_family, run_style)
            self.pdf.set_font(run_family, run_style, size)
            self.pdf.text(cursor, baseline_tl, segment)
            if should_synthesize_cjk_bold(segment, run_family, run_style, cjk_bold_passes):
                dx = max(0.3, size * cjk_bold_dx)
                for pass_index in range(1, max(1, cjk_bold_passes)):
                    self.pdf.text(cursor + dx * float(pass_index), baseline_tl, segment)
            cursor += self.pdf.get_string_width(segment)
        return cursor - x

    def _measure_with_fallback(self, text: str, family: str, style: str, size: float) -> float:
        if not text:
            return 0.0
        total = 0.0
        for run_family, run_style, segment in self._split_runs(text, family, style):
            self._ensure_font(run_family, run_style)
            self.pdf.set_font(run_family, run_style, size)
            total += self.pdf.get_string_width(segment)
        return total

    # -- coordinate helpers (internal layout uses PDF-native bottom-left) --

    @staticmethod
    def baseline_bl_for_box(bottom_y: float, height: float, font_size: float) -> float:
        return bottom_y + height - font_size

    @staticmethod
    def to_tl(bottom_y: float) -> float:
        return PAGE_HEIGHT - bottom_y

    # -- main entry --

    def render(self, doc: dict, output_pdf: str) -> Dict[int, List[Overlay]]:
        node_by_id = {node["id"]: node for node in doc["nodes"]}
        children_by_parent = {entry["parent"]: entry["children"] for entry in doc["contains"]}
        document_node = node_by_id.get(doc.get("document_id"), {})
        overlays_by_page: Dict[int, List[Overlay]] = {}

        for page_index, page_id in enumerate(doc["page_order"]):
            self.pdf.add_page()
            self._current_page_index = page_index
            page_node = node_by_id.get(page_id, {})
            self._draw_page_background(page_node, document_node)
            page_overlays: List[Overlay] = []
            for child_id in children_by_parent.get(page_id, []):
                node = node_by_id.get(child_id)
                if node is None:
                    continue
                page_overlays.extend(self._render_node(node))
            overlays_by_page[page_index] = page_overlays

        self.pdf.output(output_pdf)
        return overlays_by_page

    def render_page(self, doc: dict, page_index: int, page_id: int, output_pdf: str) -> List[Overlay]:
        node_by_id = {node["id"]: node for node in doc["nodes"]}
        children_by_parent = {entry["parent"]: entry["children"] for entry in doc["contains"]}
        document_node = node_by_id.get(doc.get("document_id"), {})
        self.pdf.add_page()
        self._current_page_index = 0
        page_node = node_by_id.get(page_id, {})
        self._draw_page_background(page_node, document_node)
        overlays: List[Overlay] = []
        for child_id in children_by_parent.get(page_id, []):
            node = node_by_id.get(child_id)
            if node is None:
                continue
            overlays.extend(self._render_node(node))
        self.pdf.output(output_pdf)
        return overlays

    def _render_node(self, node: dict) -> List[Overlay]:
        render = node_render(node)
        x = float(node.get("x") or 0.0)
        y = float(node.get("y") or 0.0)
        width = float(node.get("width") or 0.0)
        height = float(node.get("height") or 0.0)

        self._mark_internal_link_destination(node, y, height)
        self._draw_node_chrome(render, x, y, width, height)
        kind = render.get("kind")
        content = node.get("content") or ""

        if kind == "chrome_only":
            return []
        if kind == "text":
            return self._render_text_node(render, x, y, width, height, node)
        if kind == "vector_math":
            return self._render_vector_math(render, x, y, width, height, content, node)
        if kind == "vector_asset":
            return self._render_vector_asset(x, y, width, height, content)
        if kind == "raster_asset":
            return self._render_raster_asset(x, y, width, height, content)
        if kind == "code":
            self._render_code_node(render, x, y, width, height, content)
            return []
        raise RuntimeError(f"unknown render kind: {kind}")

    # -- chrome --

    def _draw_page_background(self, page_node: dict, document_node: dict) -> None:
        fill = background_color_for_page(page_node, document_node)
        if fill is None:
            return
        self._set_fill(fill)
        self.pdf.set_line_width(0)
        self.pdf.rect(0, 0, PAGE_WIDTH, PAGE_HEIGHT, style="F")

    def _draw_node_chrome(self, render: dict, x: float, y: float, width: float, height: float) -> None:
        rule = render_rule_section(render)
        if rule.get("stroke") is not None:
            stroke = parse_color_array(rule["stroke"])
            line_width = float(rule["line_width"])
            dash = parse_dash_array(rule.get("dash"))
            mid_y_bl = y + max(height / 2.0, 1.5)
            self._stroke_horizontal_line(x, mid_y_bl, x + width, line_width, stroke, dash)

        chrome = render_chrome_section(render)
        fill = parse_optional_color_array(chrome.get("fill"))
        stroke = parse_optional_color_array(chrome.get("stroke"))
        line_width = float(chrome.get("line_width", 1.0))
        radius = float(chrome.get("radius", 10.0))
        if fill is not None or stroke is not None:
            pad_x = float(chrome.get("pad_x", 0.0))
            pad_y = float(chrome.get("pad_y", 0.0))
            chrome_x = x - pad_x
            chrome_y = y - pad_y
            chrome_width = width + pad_x * 2.0
            chrome_height = height + pad_y * 2.0
            top_y = self.to_tl(chrome_y + chrome_height)
            self._set_fill(fill if fill is not None else (1.0, 1.0, 1.0))
            self._set_stroke(stroke if stroke is not None else (0.0, 0.0, 0.0))
            self.pdf.set_line_width(line_width)
            style = ""
            if fill is not None:
                style += "F"
            if stroke is not None:
                style += "D"
            self.pdf.rect(
                chrome_x,
                top_y,
                chrome_width,
                chrome_height,
                style=style or "D",
                round_corners=radius > 0,
                corner_radius=radius,
            )

        underline = render_underline_section(render)
        if underline.get("color") is not None:
            color = parse_color_array(underline["color"])
            ul_width = float(underline["width"])
            offset = float(underline["offset"])
            line_y_bl = y + offset
            self._stroke_horizontal_line(x, line_y_bl, x + width, ul_width, color, None)

    def _stroke_horizontal_line(
        self,
        x1: float,
        y_bl: float,
        x2: float,
        line_width: float,
        color: Color,
        dash: Optional[Tuple[float, float]],
    ) -> None:
        self._set_stroke(color)
        self.pdf.set_line_width(line_width)
        if dash is not None:
            self.pdf.set_dash_pattern(dash=dash[0], gap=dash[1])
        top_y = self.to_tl(y_bl)
        self.pdf.line(x1, top_y, x2, top_y)
        if dash is not None:
            self.pdf.set_dash_pattern()

    def _set_fill(self, rgb: Color) -> None:
        r, g, b = rgb_to_bytes(rgb)
        self.pdf.set_fill_color(r, g, b)

    def _set_stroke(self, rgb: Color) -> None:
        r, g, b = rgb_to_bytes(rgb)
        self.pdf.set_draw_color(r, g, b)

    def _set_text_color(self, rgb: Color) -> None:
        r, g, b = rgb_to_bytes(rgb)
        self.pdf.set_text_color(r, g, b)

    # -- text --

    def _render_text_node(
        self,
        render: dict,
        x: float,
        y: float,
        width: float,
        height: float,
        node: dict,
    ) -> List[Overlay]:
        spec = text_spec(render, node)
        baseline_bl = self.baseline_bl_for_box(y, height, spec.font_size)
        blocks = markdown_blocks_for_node(node)
        if blocks is not None:
            overlays, _ = self._draw_markdown_blocks(spec, x, baseline_bl, blocks, width)
            return overlays
        wrap = bool(render_text_section(render).get("wrap", True))
        overlays, _ = self._draw_inline_lines(spec, x, baseline_bl, inline_lines_for_node(node), width, wrap)
        return overlays

    def _draw_markdown_blocks(
        self,
        spec: TextPaintSpec,
        x: float,
        baseline_bl: float,
        blocks: List[dict],
        max_width: float,
        list_depth: int = 0,
    ) -> Tuple[List[Overlay], float]:
        overlays: List[Overlay] = []
        cursor_bl = baseline_bl
        if blocks:
            cursor_bl = baseline_bl + spec.font_size - self._markdown_block_ascent(spec, blocks[0])
        for index, block in enumerate(blocks):
            kind = str(block.get("kind", "paragraph"))
            if kind == "paragraph":
                lines = inline_lines_from_lines_field(block)
                display_math = display_math_text_from_lines(lines)
                if display_math is not None:
                    block_overlays, cursor_bl = self._draw_display_math_block(spec, x, cursor_bl, display_math, max_width)
                else:
                    block_overlays, cursor_bl = self._draw_inline_lines(spec, x, cursor_bl, lines, max_width, True)
                overlays.extend(block_overlays)
            elif kind == "code_block":
                block_overlays, cursor_bl = self._draw_markdown_code_block(
                    spec,
                    x,
                    cursor_bl,
                    block,
                    max_width,
                )
                overlays.extend(block_overlays)
            elif kind in ("bullet_list", "ordered_list"):
                start = int(block.get("start", 1))
                items = block.get("items", []) if isinstance(block.get("items"), list) else []
                list_inset = max(0.0, spec.markdown_list_inset) if list_depth == 0 else 0.0
                item_x = x + list_inset
                item_width = max(1.0, max_width - list_inset)
                for item_index, item in enumerate(items):
                    item_blocks = item.get("blocks", []) if isinstance(item, dict) else []
                    marker = self._list_marker(kind, list_depth, start + item_index)
                    item_overlays, cursor_bl = self._draw_list_item(
                        spec,
                        item_x,
                        cursor_bl,
                        item_blocks,
                        item_width,
                        marker,
                        list_depth,
                    )
                    overlays.extend(item_overlays)
                    if item_index != len(items) - 1:
                        cursor_bl -= spec.markdown_block_gap
            if index != len(blocks) - 1:
                bottom_bl = self._markdown_block_bottom(spec, block, cursor_bl)
                gap = self._markdown_gap_between_blocks(spec, block, blocks[index + 1])
                cursor_bl = bottom_bl - gap - self._markdown_block_ascent(spec, blocks[index + 1])
        return overlays, cursor_bl

    def _draw_list_item(
        self,
        spec: TextPaintSpec,
        x: float,
        baseline_bl: float,
        blocks: List[dict],
        max_width: float,
        marker: str,
        list_depth: int,
    ) -> Tuple[List[Overlay], float]:
        overlays: List[Overlay] = []
        family, style = resolve_alias(spec.font_name)
        marker_gap = max(8.0, spec.font_size * 0.35)
        marker_width = self._measure(family, style, spec.font_size, marker)
        content_x = x + marker_width + marker_gap
        content_width = max(1.0, max_width - marker_width - marker_gap)

        if blocks and isinstance(blocks[0], dict) and str(blocks[0].get("kind", "")) == "paragraph":
            self._set_text_color(spec.color)
            self._draw_text_with_fallback(
                x,
                self.to_tl(baseline_bl),
                marker,
                family,
                style,
                spec.font_size,
                spec.cjk_bold_passes,
                spec.cjk_bold_dx,
            )

        if not blocks:
            return overlays, baseline_bl - spec.line_height

        cursor_bl = baseline_bl + spec.font_size - self._markdown_block_ascent(spec, blocks[0])
        for block_index, block in enumerate(blocks):
            kind = str(block.get("kind", "paragraph"))
            if kind == "paragraph":
                lines = inline_lines_from_lines_field(block)
                display_math = display_math_text_from_lines(lines)
                if display_math is not None:
                    block_overlays, cursor_bl = self._draw_display_math_block(
                        spec,
                        content_x,
                        cursor_bl,
                        display_math,
                        content_width,
                    )
                else:
                    block_overlays, cursor_bl = self._draw_inline_lines(
                        spec,
                        content_x,
                        cursor_bl,
                        lines,
                        content_width,
                        True,
                    )
                overlays.extend(block_overlays)
            elif kind == "code_block":
                block_overlays, cursor_bl = self._draw_markdown_code_block(
                    spec,
                    content_x,
                    cursor_bl,
                    block,
                    content_width,
                )
                overlays.extend(block_overlays)
            elif kind in ("bullet_list", "ordered_list"):
                start = int(block.get("start", 1))
                items = block.get("items", []) if isinstance(block.get("items"), list) else []
                nested_x = content_x + spec.markdown_list_indent
                nested_width = max(1.0, content_width - spec.markdown_list_indent)
                for item_index, item in enumerate(items):
                    item_blocks = item.get("blocks", []) if isinstance(item, dict) else []
                    nested_marker = self._list_marker(kind, list_depth + 1, start + item_index)
                    item_overlays, cursor_bl = self._draw_list_item(
                        spec,
                        nested_x,
                        cursor_bl,
                        item_blocks,
                        nested_width,
                        nested_marker,
                        list_depth + 1,
                    )
                    overlays.extend(item_overlays)
                    if item_index != len(items) - 1:
                        cursor_bl -= spec.markdown_block_gap
            if block_index != len(blocks) - 1:
                bottom_bl = self._markdown_block_bottom(spec, block, cursor_bl)
                gap = self._markdown_gap_between_blocks(spec, block, blocks[block_index + 1])
                cursor_bl = bottom_bl - gap - self._markdown_block_ascent(spec, blocks[block_index + 1])

        return overlays, cursor_bl

    def _markdown_block_ascent(self, spec: TextPaintSpec, block: dict) -> float:
        kind = str(block.get("kind", "paragraph"))
        if kind == "code_block":
            return spec.markdown_code_font_size + spec.markdown_code_pad_y
        return spec.font_size

    def _markdown_block_bottom(self, spec: TextPaintSpec, block: dict, cursor_bl: float) -> float:
        kind = str(block.get("kind", "paragraph"))
        if kind == "code_block":
            return cursor_bl
        return cursor_bl + spec.font_size

    def _markdown_gap_between_blocks(self, spec: TextPaintSpec, current: dict, next_block: dict) -> float:
        current_kind = str(current.get("kind", "paragraph"))
        next_kind = str(next_block.get("kind", "paragraph"))
        if current_kind == "code_block" or next_kind == "code_block":
            return max(spec.markdown_block_gap, spec.line_height)
        return spec.markdown_block_gap

    def _draw_markdown_code_block(
        self,
        spec: TextPaintSpec,
        x: float,
        baseline_bl: float,
        block: dict,
        max_width: float,
    ) -> Tuple[List[Overlay], float]:
        overlays: List[Overlay] = []
        code_font_size = spec.markdown_code_font_size
        code_line_height = spec.markdown_code_line_height
        pad_x = spec.markdown_code_pad_x
        pad_y = spec.markdown_code_pad_y
        language = str(block["language"]) if block.get("language") else None
        inner_x = x + pad_x
        inner_width = max(1.0, max_width - 2.0 * pad_x)
        line_texts = code_plain_lines_from_block(block)
        line_count = max(1, len(line_texts))
        box_height = line_count * code_line_height + 2.0 * pad_y
        box_bottom = baseline_bl - (line_count * code_line_height - code_font_size) - pad_y

        if spec.markdown_code_fill is not None or spec.markdown_code_stroke is not None:
            top_y = self.to_tl(box_bottom + box_height)
            self._set_fill(spec.markdown_code_fill if spec.markdown_code_fill is not None else (1.0, 1.0, 1.0))
            self._set_stroke(spec.markdown_code_stroke if spec.markdown_code_stroke is not None else (0.0, 0.0, 0.0))
            self.pdf.set_line_width(spec.markdown_code_line_width)
            style = ""
            if spec.markdown_code_fill is not None:
                style += "F"
            if spec.markdown_code_stroke is not None:
                style += "D"
            self.pdf.rect(
                x,
                top_y,
                max_width,
                box_height,
                style=style or "D",
                round_corners=spec.markdown_code_radius > 0,
                corner_radius=spec.markdown_code_radius,
            )

        cursor_bl = baseline_bl
        highlighter = CODE_HIGHLIGHTERS.get(language) if language else None
        code_info: dict = {}
        if highlighter is not None:
            code_lines = load_highlighted_code_lines(highlighter, "\n".join(line_texts), self.highlight_cache_dir)
        else:
            code_lines = [[{"text": line, "class": "plain"}] for line in line_texts] or [[{"text": "", "class": "plain"}]]
        self._draw_code_lines(
            inner_x,
            cursor_bl,
            inner_width,
            code_lines,
            spec.code_font_name,
            code_font_size,
            code_line_height,
            spec.color,
            code_info,
            spec.cjk_bold_passes,
            spec.cjk_bold_dx,
        )
        return overlays, box_bottom

    def _list_marker(self, kind: str, list_depth: int, ordinal: int) -> str:
        if kind == "ordered_list":
            return f"{ordinal}."
        return "•" if list_depth == 0 else "◦"

    def _draw_inline_lines(
        self,
        spec: TextPaintSpec,
        x: float,
        baseline_bl: float,
        inline_lines: List[List[dict]],
        max_width: float,
        enable_wrapping: bool,
    ) -> Tuple[List[Overlay], float]:
        overlays: List[Overlay] = []
        cursor_bl = baseline_bl
        for line in inline_lines or [[]]:
            atoms = self._layout_atoms(line, spec)
            wrapped = wrap_atoms(atoms, max_width) if enable_wrapping else [atoms]
            if not wrapped:
                wrapped = [[]]
            for atoms_on_line in wrapped:
                cursor_x = x
                for atom in atoms_on_line:
                    if atom["kind"] == "math":
                        target_w = atom["width"]
                        target_h = atom["height"]
                        overlays.append(
                            Overlay(
                                atom["pdf_path"],
                                cursor_x,
                                cursor_bl - target_h * 0.25,
                                target_w,
                                target_h,
                            )
                        )
                        cursor_x += target_w + spec.font_size * spec.inline_math_spacing
                        continue
                    if atom["kind"] == "icon":
                        target_w = atom["width"]
                        target_h = atom["height"]
                        overlays.append(
                            Overlay(
                                atom["pdf_path"],
                                cursor_x,
                                cursor_bl - target_h * 0.22,
                                target_w,
                                target_h,
                            )
                        )
                        cursor_x += target_w
                        continue
                    self._draw_text_atom(atom, spec, cursor_x, cursor_bl)
                    cursor_x += atom["width"]
                cursor_bl -= spec.line_height
        return overlays, cursor_bl

    def _draw_display_math_block(
        self,
        spec: TextPaintSpec,
        x: float,
        baseline_bl: float,
        tex_body: str,
        max_width: float,
    ) -> Tuple[List[Overlay], float]:
        pdf_path = render_display_math_to_pdf(tex_body, self.math_cache_dir, spec.color, spec.math_latex_packages)
        src_w, src_h = pdf_page_size(pdf_path)
        scale = (spec.font_size / LATEX_DEFAULT_FONT_SIZE_PT) * DISPLAY_MATH_FONT_SCALE
        target_w = src_w * scale
        target_h = src_h * scale
        overlay_x = x + (max_width - target_w) / 2.0
        return [
            Overlay(
                pdf_path,
                overlay_x,
                baseline_bl - target_h * 0.25,
                target_w,
                target_h,
            )
        ], baseline_bl - spec.line_height

    def _draw_text_atom(self, atom: dict, spec: TextPaintSpec, x: float, baseline_bl: float) -> None:
        text = atom["text"]
        if not text:
            return
        family, style = atom["family"], atom["style"]
        kind = atom["kind"]
        rgb = spec.link_color if kind == "link" else atom.get("color", spec.color)
        self._set_text_color(rgb)
        baseline_tl = self.to_tl(baseline_bl)
        self._draw_text_with_fallback(
            x,
            baseline_tl,
            text,
            family,
            style,
            spec.font_size,
            spec.cjk_bold_passes,
            spec.cjk_bold_dx,
        )
        if kind == "link":
            width = atom["width"]
            underline_y_bl = baseline_bl + spec.link_underline_offset
            self._stroke_horizontal_line(
                x,
                underline_y_bl,
                x + width,
                spec.link_underline_width,
                rgb,
                None,
            )
            url = atom.get("url")
            if url:
                # fpdf2 link rectangle uses top-left coords
                rect_top = self.to_tl(baseline_bl + spec.font_size)
                rect_h = spec.font_size * 1.2
                self.pdf.link(x, rect_top, width, rect_h, link=self._link_target(url))

    def _mark_internal_link_destination(self, node: dict, y: float, height: float) -> None:
        properties = node.get("properties")
        if not isinstance(properties, dict):
            return
        link_id = properties.get("link_id")
        if not isinstance(link_id, str) or not link_id:
            return
        target = self._internal_link(link_id)
        self.pdf.set_link(target, y=self.to_tl(y + height), page=self._current_page_index + 1)

    def _link_target(self, url: str):
        if url.startswith("#") and len(url) > 1:
            return self._internal_link(url[1:])
        return url

    def _internal_link(self, link_id: str) -> int:
        target = self._internal_links.get(link_id)
        if target is None:
            target = self.pdf.add_link()
            self._internal_links[link_id] = target
        return target

    def _layout_atoms(self, line: List[dict], spec: TextPaintSpec) -> List[dict]:
        atoms: List[dict] = []
        for run in line:
            kind = str(run.get("kind", "text"))
            segment = str(run.get("text", ""))
            if kind in ("math", "display_math"):
                color = parse_color_array(run.get("color")) if run.get("color") is not None else spec.color
                pdf_path = render_inline_math_to_pdf(segment, self.math_cache_dir, color, spec.math_latex_packages)
                src_w, src_h = pdf_page_size(pdf_path)
                target_h = spec.font_size * spec.inline_math_height_factor
                scale = target_h / src_h if src_h > 0 else 1.0
                target_w = src_w * scale
                atoms.append(
                    {
                        "kind": "math",
                        "pdf_path": pdf_path,
                        "width": target_w,
                        "height": target_h,
                        "is_space": False,
                    }
                )
                continue
            if kind == "icon":
                icon_ref = str(run.get("icon", ""))
                if not icon_ref:
                    continue
                pdf_path = render_inline_icon_to_pdf(icon_ref, self.icon_cache_dir)
                src_w, src_h = pdf_page_size(pdf_path)
                target_h = spec.font_size * 1.05
                scale = target_h / src_h if src_h > 0 else 1.0
                target_w = src_w * scale
                atoms.append(
                    {
                        "kind": "icon",
                        "pdf_path": pdf_path,
                        "width": target_w,
                        "height": target_h,
                        "is_space": False,
                    }
                )
                continue

            family, style = self._family_style_for_inline(spec, kind)
            url = str(run["url"]) if kind == "link" and run.get("url") is not None else None
            for piece in split_text_for_wrapping(segment):
                width = self._measure(family, style, spec.font_size, piece)
                atoms.append(
                    {
                        "kind": kind,
                        "text": piece,
                        "url": url,
                        "family": family,
                        "style": style,
                        "width": width,
                        "is_space": piece.isspace(),
                    }
                )
        return atoms

    def _family_style_for_inline(self, spec: TextPaintSpec, kind: str) -> Tuple[str, str]:
        if kind == "code":
            return resolve_alias(spec.code_font_name)
        if kind == "bold":
            return resolve_alias(spec.bold_font_name)
        if kind == "italic":
            return resolve_alias(spec.italic_font_name)
        return resolve_alias(spec.font_name)

    def _measure(self, family: str, style: str, size: float, text: str) -> float:
        return self._measure_with_fallback(text, family, style, size)

    def _draw_code_lines(
        self,
        x: float,
        baseline_bl: float,
        _max_width: float,
        lines: List[List[dict]],
        font_name: str,
        font_size: float,
        line_height: float,
        default_color: Color,
        code_info: dict,
        cjk_bold_passes: int,
        cjk_bold_dx: float,
    ) -> None:
        family, style = resolve_alias(font_name)
        cursor_bl = baseline_bl
        for line in lines or [[]]:
            cursor_x = x
            for segment in line:
                text = str(segment.get("text", "")).expandtabs(4)
                if not text:
                    continue
                color = highlight_segment_color(str(segment.get("class", "plain")), default_color, code_info)
                self._set_text_color(color)
                cursor_x += self._draw_text_with_fallback(
                    cursor_x,
                    self.to_tl(cursor_bl),
                    text,
                    family,
                    style,
                    font_size,
                    cjk_bold_passes,
                    cjk_bold_dx,
                )
            cursor_bl -= line_height

    # -- code --

    def _render_code_node(
        self,
        render: dict,
        x: float,
        y: float,
        _width: float,
        height: float,
        content: str,
    ) -> None:
        spec = text_spec(render)
        code_info = render_code_section(render)
        baseline_bl = self.baseline_bl_for_box(y, height, spec.font_size)
        highlighter = code_highlighter_spec(render)
        if highlighter is not None:
            lines = load_highlighted_code_lines(highlighter, content, self.highlight_cache_dir)
        else:
            lines = [[{"text": raw, "class": "plain"}] for raw in (content.splitlines() or [""])]
        self._draw_code_lines(
            x,
            baseline_bl,
            _width,
            lines,
            spec.code_font_name,
            spec.font_size,
            spec.line_height,
            spec.color,
            code_info,
            spec.cjk_bold_passes,
            spec.cjk_bold_dx,
        )

    # -- vector math --

    def _render_vector_math(
        self,
        render: dict,
        x: float,
        y: float,
        width: float,
        height: float,
        content: str,
        node: dict,
    ) -> List[Overlay]:
        math = render.get("math") or {}
        color = parse_color_array(math.get("color")) if math.get("color") is not None else (0.0, 0.0, 0.0)
        pdf_path = render_math_tex_to_pdf(content, self.math_cache_dir, color, math_packages_for_node(node))
        src_w, src_h = pdf_page_size(pdf_path)
        display_w, display_h = fit_math_block_size(render, src_w, src_h, width, height, content)
        return [Overlay(pdf_path, x, y + max(0.0, (height - display_h) / 2.0), display_w, display_h)]

    def _render_vector_asset(
        self,
        x: float,
        y: float,
        width: float,
        height: float,
        content: str,
    ) -> List[Overlay]:
        source = resolve_asset_path(self.asset_base_dir, content)
        src_w, src_h = pdf_page_size(source)
        display_w, display_h = fit_size(src_w, src_h, width, height)
        return [Overlay(source, x, y + max(0.0, (height - display_h) / 2.0), display_w, display_h)]

    def _render_raster_asset(
        self,
        x: float,
        y: float,
        width: float,
        height: float,
        content: str,
    ) -> List[Overlay]:
        source = resolve_asset_path(self.asset_base_dir, content)
        if is_svg_asset(source):
            pdf_path = render_svg_asset_to_pdf(source, self.svg_asset_cache_dir)
            src_w, src_h = pdf_page_size(pdf_path)
            display_w, display_h = fit_size(src_w, src_h, width, height)
            return [Overlay(pdf_path, x, y + max(0.0, (height - display_h) / 2.0), display_w, display_h)]

        src_w, src_h = image_size(source)
        display_w, display_h = fit_size(src_w, src_h, width, height)
        top_y = self.to_tl(y + height)
        offset = max(0.0, (height - display_h) / 2.0)
        self.pdf.image(
            source,
            x=x,
            y=top_y + offset,
            w=display_w,
            h=display_h,
            keep_aspect_ratio=True,
        )
        return []


# ---------------------------------------------------------------------------
# Overlay merge


def merge_overlays(base_pdf: str, output_pdf: str, overlays_by_page: Dict[int, List[Overlay]]) -> None:
    reader = PdfReader(base_pdf)
    writer = PdfWriter()
    overlay_cache: Dict[str, Tuple[PdfReader, object, float, float, float, float]] = {}

    for index, page in enumerate(reader.pages):
        overlays = overlays_by_page.get(index, [])
        for overlay in overlays:
            cached = overlay_cache.get(overlay.pdf_path)
            if cached is None:
                src_reader = PdfReader(overlay.pdf_path)
                src_page = src_reader.pages[0]
                left = float(src_page.mediabox.left)
                bottom = float(src_page.mediabox.bottom)
                width = float(src_page.mediabox.width)
                height = float(src_page.mediabox.height)
                cached = (src_reader, src_page, left, bottom, width, height)
                overlay_cache[overlay.pdf_path] = cached
            _src_reader, src_page, left, bottom, width, height = cached
            sx = overlay.width / width
            sy = overlay.height / height
            transform = (
                Transformation()
                .translate(tx=-left, ty=-bottom)
                .scale(sx=sx, sy=sy)
                .translate(tx=overlay.x, ty=overlay.y)
            )
            page.merge_transformed_page(src_page, transform, over=True)
        writer.add_page(page)

    with open(output_pdf, "wb") as f:
        writer.write(f)


# ---------------------------------------------------------------------------
# Incremental page rendering


def supports_incremental_render(doc: dict) -> bool:
    """Page PDFs are reusable when internal links do not cross page boundaries."""
    node_by_id = {node["id"]: node for node in doc.get("nodes", []) if isinstance(node, dict) and "id" in node}
    children_by_parent = {
        entry["parent"]: entry["children"]
        for entry in doc.get("contains", [])
        if isinstance(entry, dict) and "parent" in entry and isinstance(entry.get("children"), list)
    }

    page_by_node: Dict[int, int] = {}

    def visit(node_id: int, page_id: int) -> None:
        if node_id in page_by_node:
            return
        page_by_node[node_id] = page_id
        for child_id in children_by_parent.get(node_id, []):
            visit(child_id, page_id)

    for page_id in doc.get("page_order", []):
        if page_id in node_by_id:
            visit(page_id, page_id)

    target_pages: Dict[str, int] = {}
    for node in node_by_id.values():
        properties = node.get("properties")
        link_id = properties.get("link_id") if isinstance(properties, dict) else None
        if not isinstance(link_id, str) or not link_id:
            continue
        page_id = page_by_node.get(node["id"])
        if page_id is None:
            return False
        existing = target_pages.get(link_id)
        if existing is not None and existing != page_id:
            return False
        target_pages[link_id] = page_id

    for node in node_by_id.values():
        source_page = page_by_node.get(node["id"])
        for link_id in internal_link_ids_for_node(node):
            target_page = target_pages.get(link_id)
            if source_page is None or target_page is None or source_page != target_page:
                return False
    return True


def internal_link_ids_for_node(node: dict) -> List[str]:
    link_ids: List[str] = []
    for line in node.get("inline_lines") or []:
        link_ids.extend(internal_link_ids_for_line(line))
    for block in node.get("blocks") or []:
        link_ids.extend(internal_link_ids_for_block(block))
    return link_ids


def internal_link_ids_for_block(block: dict) -> List[str]:
    link_ids: List[str] = []
    if not isinstance(block, dict):
        return link_ids
    for line in block.get("lines") or []:
        link_ids.extend(internal_link_ids_for_line(line))
    for item in block.get("items") or []:
        if not isinstance(item, dict):
            continue
        for child in item.get("blocks") or []:
            link_ids.extend(internal_link_ids_for_block(child))
    return link_ids


def internal_link_ids_for_line(line: object) -> List[str]:
    link_ids: List[str] = []
    if not isinstance(line, list):
        return link_ids
    for segment in line:
        if not isinstance(segment, dict):
            continue
        url = segment.get("url")
        if isinstance(url, str) and url.startswith(INTERNAL_LINK_PREFIX) and len(url) > len(INTERNAL_LINK_PREFIX):
            link_ids.append(url[len(INTERNAL_LINK_PREFIX) :])
    return link_ids


class IncrementalPageRenderer:
    def __init__(self, doc: dict, output_pdf: str, asset_base_dir: str, caches: RuntimeCaches) -> None:
        self.doc = doc
        self.output_pdf = output_pdf
        self.asset_base_dir = asset_base_dir
        self.caches = caches
        self.node_by_id = {node["id"]: node for node in doc["nodes"]}
        self.children_by_parent = {entry["parent"]: entry["children"] for entry in doc["contains"]}

    def render(self) -> IncrementalRenderStats:
        self.caches.ensure_page_cache()

        previous_manifest = self._read_manifest()
        pages: List[CachedPage] = []
        for page_index, page_id in enumerate(self.doc["page_order"]):
            pages.append(self._cached_page(page_index, page_id))

        for page in pages:
            if page.pdf_path.exists():
                touch_cache_entry(page.pdf_path)
        missing = [page for page in pages if not page.pdf_path.exists()]
        rendered = len(missing)
        reused = len(pages) - rendered
        document_pdf = self._document_pdf_path(pages)
        changed_indexes = self._changed_indexes(previous_manifest, pages)
        previous_document_pdf = self._previous_document_pdf(previous_manifest)

        if not missing and document_pdf.exists():
            touch_cache_entry(document_pdf)
            self._copy_cached_document(document_pdf)
            self._write_manifest(pages, rendered, reused)
            return IncrementalRenderStats(rendered=rendered, reused=reused, total=len(pages))

        if rendered == len(pages) and pages:
            render_full_document(self.doc, self.output_pdf, self.asset_base_dir, self.caches)
            self._cache_pages_from_output(pages)
            self._cache_document_output(document_pdf)
            self._write_manifest(pages, rendered, reused)
            return IncrementalRenderStats(rendered=rendered, reused=reused, total=len(pages))

        prewarm_math_cache_for_pages(self.doc, missing_page_ids=[page.page_id for page in missing], cache_dir=self.caches.math_dir)
        for page in missing:
            self._render_page(page)

        if (
            len(changed_indexes) == 1
            and previous_document_pdf is not None
            and self._assemble_by_replacing_page(previous_document_pdf, pages[changed_indexes[0]])
        ):
            pass
        else:
            self._assemble(pages)
        self._cache_document_output(document_pdf)
        self._write_manifest(pages, rendered, reused)
        return IncrementalRenderStats(rendered=rendered, reused=reused, total=len(pages))

    def _cached_page(self, page_index: int, page_id: int) -> CachedPage:
        digest = self._page_digest(page_id)
        page_node = self.node_by_id.get(page_id, {})
        return CachedPage(
            index=page_index,
            page_id=page_id,
            name=page_node.get("name"),
            digest=digest,
            pdf_path=self.caches.page_dir / f"{digest}{PDF_SUFFIX}",
        )

    def _render_page(self, page: CachedPage) -> None:
        tmp_base_pdf = self.caches.temp_pdf(TMP_PAGE_BASE_LABEL, page.digest)
        tmp_page_pdf = self.caches.temp_pdf(TMP_PAGE_FINAL_LABEL, page.digest)
        try:
            renderer = Renderer(self.asset_base_dir, self.caches.math_dir, self.caches.highlight_dir, self.caches.icon_dir, self.caches.svg_asset_dir)
            overlays = renderer.render_page(self.doc, page.index, page.page_id, str(tmp_base_pdf))
            if overlays:
                merge_overlays(str(tmp_base_pdf), str(tmp_page_pdf), {0: overlays})
                tmp_page_pdf.replace(page.pdf_path)
            else:
                tmp_base_pdf.replace(page.pdf_path)
        finally:
            tmp_base_pdf.unlink(missing_ok=True)
            tmp_page_pdf.unlink(missing_ok=True)

    def _assemble(self, pages: List[CachedPage]) -> None:
        writer = PdfWriter()
        for page in pages:
            touch_cache_entry(page.pdf_path)
            reader = PdfReader(str(page.pdf_path))
            writer.add_page(reader.pages[0])
        with open(self.output_pdf, "wb") as f:
            writer.write(f)

    def _assemble_by_replacing_page(self, previous_document_pdf: Path, page: CachedPage) -> bool:
        qpdf = shutil.which("qpdf")
        if qpdf is None:
            return False

        total_pages = len(self.doc["page_order"])
        argv = [qpdf, "--empty", "--pages"]
        if page.index > 0:
            argv.extend([str(previous_document_pdf), f"1-{page.index}"])
        argv.extend([str(page.pdf_path), "1"])
        if page.index + 1 < total_pages:
            argv.extend([str(previous_document_pdf), f"{page.index + 2}-z"])
        argv.extend(["--", self.output_pdf])

        try:
            subprocess.run(argv, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except (OSError, subprocess.CalledProcessError) as err:
            if isinstance(err, subprocess.CalledProcessError):
                stderr = err.stderr.decode("utf-8", errors="replace") if err.stderr else ""
                print(f"pdf backend: qpdf page replacement failed, falling back to pypdf assemble: {stderr}", file=sys.stderr)
            return False
        return True

    def _cache_pages_from_output(self, pages: List[CachedPage]) -> None:
        reader = PdfReader(self.output_pdf)
        if len(reader.pages) != len(pages):
            raise RuntimeError(f"expected {len(pages)} rendered pages, got {len(reader.pages)}")
        for page in pages:
            tmp_page_pdf = self.caches.temp_pdf(TMP_PAGE_FINAL_LABEL, page.digest)
            try:
                writer = PdfWriter()
                writer.add_page(reader.pages[page.index])
                with open(tmp_page_pdf, "wb") as f:
                    writer.write(f)
                tmp_page_pdf.replace(page.pdf_path)
            finally:
                tmp_page_pdf.unlink(missing_ok=True)

    def _write_manifest(self, pages: List[CachedPage], rendered: int, reused: int) -> None:
        manifest = {
            "version": INCREMENTAL_RENDER_VERSION,
            "renderer": renderer_fingerprint(),
            "project_path": self.doc.get("project_path"),
            "asset_base_dir": self.doc.get("asset_base_dir"),
            "rendered": rendered,
            "reused": reused,
            "pages": [page.manifest_entry() for page in pages],
        }
        self._manifest_path().write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")

    def _read_manifest(self) -> Optional[dict]:
        path = self._manifest_path()
        try:
            manifest = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if manifest.get("version") != INCREMENTAL_RENDER_VERSION:
            return None
        if manifest.get("renderer") != renderer_fingerprint():
            return None
        if manifest.get("project_path") != self.doc.get("project_path"):
            return None
        if manifest.get("asset_base_dir") != self.doc.get("asset_base_dir"):
            return None
        if not isinstance(manifest.get("pages"), list):
            return None
        return manifest

    def _changed_indexes(self, previous_manifest: Optional[dict], pages: List[CachedPage]) -> List[int]:
        if previous_manifest is None:
            return []
        previous_pages = previous_manifest.get("pages")
        if not isinstance(previous_pages, list) or len(previous_pages) != len(pages):
            return []
        changed: List[int] = []
        for index, (previous_page, page) in enumerate(zip(previous_pages, pages)):
            previous_digest = previous_page.get("hash") if isinstance(previous_page, dict) else None
            if previous_digest != page.digest:
                changed.append(index)
        return changed

    def _previous_document_pdf(self, previous_manifest: Optional[dict]) -> Optional[Path]:
        if previous_manifest is None:
            return None
        previous_pages = previous_manifest.get("pages")
        if not isinstance(previous_pages, list):
            return None
        digests: List[str] = []
        for page in previous_pages:
            digest = page.get("hash") if isinstance(page, dict) else None
            if not isinstance(digest, str) or not digest:
                return None
            digests.append(digest)
        document_pdf = self._document_pdf_path_for_digests(digests)
        return document_pdf if document_pdf.exists() else None

    def _document_pdf_path(self, pages: List[CachedPage]) -> Path:
        return self._document_pdf_path_for_digests([page.digest for page in pages])

    def _document_pdf_path_for_digests(self, page_digests: List[str]) -> Path:
        identity = hashlib.sha256(
            json.dumps(
                {
                    "version": INCREMENTAL_RENDER_VERSION,
                    "renderer": renderer_fingerprint(),
                    "project_path": self.doc.get("project_path"),
                    "asset_base_dir": self.doc.get("asset_base_dir"),
                    "pages": page_digests,
                },
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        return self.caches.document_dir / f"{identity}{PDF_SUFFIX}"

    def _cache_document_output(self, document_pdf: Path) -> None:
        output_path = Path(self.output_pdf)
        if output_path.resolve() == document_pdf.resolve():
            return
        tmp_pdf = self.caches.temp_pdf("document-cache", document_pdf.stem)
        try:
            shutil.copyfile(self.output_pdf, tmp_pdf)
            tmp_pdf.replace(document_pdf)
        finally:
            tmp_pdf.unlink(missing_ok=True)

    def _copy_cached_document(self, document_pdf: Path) -> None:
        output_path = Path(self.output_pdf)
        if output_path.resolve() == document_pdf.resolve():
            return
        touch_cache_entry(document_pdf)
        shutil.copyfile(document_pdf, output_path)

    def _manifest_path(self) -> Path:
        identity = hashlib.sha256(
            json.dumps(
                {
                    "project_path": self.doc.get("project_path"),
                    "asset_base_dir": self.doc.get("asset_base_dir"),
                },
                sort_keys=True,
            ).encode("utf-8")
        ).hexdigest()[:20]
        return self.caches.manifest_dir / f"{identity}.json"

    def _page_digest(self, page_id: int) -> str:
        payload = {
            "version": INCREMENTAL_RENDER_VERSION,
            "renderer": renderer_fingerprint(),
            "ir_version": self.doc.get("ir_version"),
            "page": self._normalized_page_payload(page_id),
        }
        return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()

    def _normalized_page_payload(self, page_id: int) -> dict:
        page_node = self.node_by_id.get(page_id, {})
        document_node = self.node_by_id.get(self.doc.get("document_id"), {})
        local_ids: Dict[int, int] = {}
        ordered_ids: List[int] = []

        def visit(node_id: int) -> None:
            if node_id in local_ids:
                return
            local_ids[node_id] = len(local_ids) + 1
            ordered_ids.append(node_id)
            for child_id in self.children_by_parent.get(node_id, []):
                visit(child_id)

        visit(page_id)
        return {
            "name": page_node.get("name"),
            "document_background_fill": node_property(document_node, "background_fill"),
            "direct_children": [
                local_ids[child]
                for child in self.children_by_parent.get(page_id, [])
                if child in local_ids
            ],
            "nodes": [self._normalized_node(self.node_by_id.get(node_id, {})) for node_id in ordered_ids],
            "contains": [
                {
                    "parent": local_ids[parent],
                    "children": [local_ids[child] for child in children if child in local_ids],
                }
                for parent, children in sorted(self.children_by_parent.items())
                if parent in local_ids
            ],
        }

    def _normalized_node(self, node: dict) -> dict:
        normalized = {
            key: value
            for key, value in node.items()
            if key not in {"id", "origin", "page_index"}
        }
        render = normalized.get("render")
        kind = render.get("kind") if isinstance(render, dict) else None
        if kind in {"vector_asset", "raster_asset"}:
            content = normalized.get("content")
            if isinstance(content, str) and content:
                normalized["asset_fingerprint"] = file_fingerprint(resolve_asset_path(self.asset_base_dir, content))
        return normalized


def file_fingerprint(path_text: str) -> dict:
    path = Path(path_text)
    stat = path.stat()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return {
        "path": str(path),
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "sha256": digest,
    }


def renderer_fingerprint() -> str:
    global _renderer_fingerprint_cache
    if _renderer_fingerprint_cache is not None:
        return _renderer_fingerprint_cache
    chunks = [INCREMENTAL_RENDER_VERSION, MATH_RENDER_VERSION, HIGHLIGHT_RENDER_VERSION, FA_RENDER_VERSION]
    chunks.append(hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    for spec in CODE_HIGHLIGHTERS.values():
        chunks.append(hashlib.sha256(spec.script_path.read_bytes()).hexdigest())
    _renderer_fingerprint_cache = hashlib.sha256("\0".join(chunks).encode("utf-8")).hexdigest()
    return _renderer_fingerprint_cache


# ---------------------------------------------------------------------------
# Math (LaTeX -> PDF)


def prewarm_math_cache_for_doc(doc: dict, cache_dir: Path) -> None:
    page_ids = [page_id for page_id in doc.get("page_order", []) if isinstance(page_id, int)]
    prewarm_math_cache_for_pages(doc, page_ids, cache_dir)


def prewarm_math_cache_for_pages(doc: dict, missing_page_ids: List[int], cache_dir: Path) -> None:
    if not missing_page_ids:
        return
    node_by_id = {node["id"]: node for node in doc.get("nodes", []) if isinstance(node, dict) and "id" in node}
    children_by_parent = {
        entry["parent"]: entry["children"]
        for entry in doc.get("contains", [])
        if isinstance(entry, dict) and "parent" in entry and isinstance(entry.get("children"), list)
    }
    jobs_by_digest: Dict[str, MathRenderJob] = {}

    def add_job(job: MathRenderJob) -> None:
        if job.pdf_path.exists():
            return
        jobs_by_digest[job.digest] = job

    def visit(node_id: int) -> None:
        node = node_by_id.get(node_id)
        if node is None:
            return
        collect_math_jobs_for_node(node, cache_dir, add_job)
        for child_id in children_by_parent.get(node_id, []):
            visit(child_id)

    for page_id in missing_page_ids:
        visit(page_id)

    compile_missing_math_jobs(list(jobs_by_digest.values()), cache_dir)


def collect_math_jobs_for_node(node: dict, cache_dir: Path, add_job) -> None:
    if node.get("kind") != "object":
        return
    render = node_render(node)
    kind = render.get("kind")
    if kind == "vector_math":
        math = render.get("math") or {}
        color = parse_color_array(math.get("color")) if math.get("color") is not None else (0.0, 0.0, 0.0)
        add_job(make_math_job("block", str(node.get("content") or ""), cache_dir, color, math_packages_for_node(node)))
        return
    if kind != "text":
        return

    spec = text_spec(render, node)
    blocks = markdown_blocks_for_node(node)
    if blocks is not None:
        collect_math_jobs_for_blocks(blocks, spec, cache_dir, add_job)
    else:
        collect_math_jobs_for_inline_lines(inline_lines_for_node(node), spec, cache_dir, add_job)


def collect_math_jobs_for_blocks(blocks: List[dict], spec: TextPaintSpec, cache_dir: Path, add_job) -> None:
    for block in blocks:
        kind = str(block.get("kind", "paragraph"))
        if kind == "paragraph":
            lines = inline_lines_from_lines_field(block)
            display_math = display_math_text_from_lines(lines)
            if display_math is not None:
                add_job(make_math_job("display", display_math, cache_dir, spec.color, spec.math_latex_packages))
            else:
                collect_math_jobs_for_inline_lines(lines, spec, cache_dir, add_job)
        elif kind in ("bullet_list", "ordered_list"):
            items = block.get("items", []) if isinstance(block.get("items"), list) else []
            for item in items:
                item_blocks = item.get("blocks", []) if isinstance(item, dict) else []
                collect_math_jobs_for_blocks(
                    [child for child in item_blocks if isinstance(child, dict)],
                    spec,
                    cache_dir,
                    add_job,
                )


def collect_math_jobs_for_inline_lines(lines: List[List[dict]], spec: TextPaintSpec, cache_dir: Path, add_job) -> None:
    for line in lines:
        for run in line:
            kind = str(run.get("kind", "text"))
            if kind not in ("math", "display_math"):
                continue
            color = parse_color_array(run.get("color")) if run.get("color") is not None else spec.color
            add_job(make_math_job("inline", str(run.get("text", "")), cache_dir, color, spec.math_latex_packages))


def compile_missing_math_jobs(jobs: List[MathRenderJob], cache_dir: Path) -> None:
    pending = [job for job in jobs if not job.pdf_path.exists()]
    if not pending:
        return

    groups: Dict[Tuple[str, ...], List[MathRenderJob]] = {}
    for job in pending:
        groups.setdefault(job.packages, []).append(job)

    for group_jobs in groups.values():
        if len(group_jobs) == 1:
            ensure_math_pdf(group_jobs[0])
            continue
        try:
            compile_math_batch(group_jobs, cache_dir)
        except Exception:
            for job in group_jobs:
                ensure_math_pdf(job)


def compile_math_batch(jobs: List[MathRenderJob], cache_dir: Path) -> None:
    batch_key = hashlib.sha256("\0".join(job.digest for job in jobs).encode("utf-8")).hexdigest()[:16]
    batch_dir = cache_dir / f"batch-{batch_key}"
    batch_dir.mkdir(parents=True, exist_ok=True)
    batch_tex = batch_dir / "main.tex"
    batch_pdf = batch_dir / "main.pdf"
    packages = list(jobs[0].packages)
    batch_tex.write_text(batch_math_document_source(packages, jobs), encoding="utf-8")
    run_checked(["pdflatex", "-interaction=nonstopmode", "-halt-on-error", "main.tex"], cwd=str(batch_dir))

    reader = PdfReader(str(batch_pdf))
    if len(reader.pages) != len(jobs):
        raise RuntimeError(f"batch math produced {len(reader.pages)} page(s), expected {len(jobs)}")

    for index, job in enumerate(jobs):
        job.work_dir.mkdir(parents=True, exist_ok=True)
        job.tex_path.write_text(single_math_document_source(job), encoding="utf-8")
        tmp_pdf = job.work_dir / "main.batch-tmp.pdf"
        try:
            writer = PdfWriter()
            writer.add_page(reader.pages[index])
            with open(tmp_pdf, "wb") as f:
                writer.write(f)
            tmp_pdf.replace(job.pdf_path)
        finally:
            tmp_pdf.unlink(missing_ok=True)
    shutil.rmtree(batch_dir, ignore_errors=True)


def batch_math_document_source(packages: List[str], jobs: List[MathRenderJob]) -> str:
    chunks = [
        "\\documentclass[multi=ssmath,border=0pt]{standalone}\n",
        "\\usepackage{amsmath,amssymb}\n",
        "\\usepackage{graphicx}\n",
        "\\usepackage{xcolor}\n",
        latex_package_lines(packages),
        "\\begin{document}\n",
    ]
    for job in jobs:
        chunks.append("\\begin{ssmath}\n")
        chunks.append(color_command(job.color))
        chunks.append(math_tex_fragment(job))
        chunks.append("\\end{ssmath}\n")
    chunks.append("\\end{document}\n")
    return "".join(chunks)


def make_math_job(
    kind: str,
    tex_body: str,
    cache_dir: Path,
    color: Optional[Color] = None,
    packages: Optional[List[str]] = None,
) -> MathRenderJob:
    latex_packages = tuple(canonical_latex_packages(packages or []))
    color_key = color_cache_key(color)
    package_key = "\0".join(latex_packages)
    digest = hashlib.sha256((MATH_RENDER_VERSION + ":" + kind + ":" + color_key + ":" + package_key + ":" + tex_body).encode("utf-8")).hexdigest()[:16]
    work_dir = cache_dir / digest
    return MathRenderJob(
        kind=kind,
        tex_body=tex_body,
        color=color,
        packages=latex_packages,
        digest=digest,
        work_dir=work_dir,
        tex_path=work_dir / "main.tex",
        pdf_path=work_dir / "main.pdf",
    )


def ensure_math_pdf(job: MathRenderJob) -> str:
    if job.pdf_path.exists():
        touch_cache_entry(job.work_dir)
        touch_cache_entry(job.pdf_path)
        return str(job.pdf_path)
    job.work_dir.mkdir(parents=True, exist_ok=True)
    job.tex_path.write_text(single_math_document_source(job), encoding="utf-8")
    run_checked(["pdflatex", "-interaction=nonstopmode", "-halt-on-error", "main.tex"], cwd=str(job.work_dir))
    return str(job.pdf_path)


def single_math_document_source(job: MathRenderJob) -> str:
    return (
        "\\documentclass[border=0pt]{standalone}\n"
        "\\usepackage{amsmath,amssymb}\n"
        "\\usepackage{graphicx}\n"
        "\\usepackage{xcolor}\n"
        f"{latex_package_lines(list(job.packages))}"
        "\\begin{document}\n"
        f"{color_command(job.color)}"
        f"{math_tex_fragment(job)}"
        "\\end{document}\n"
    )


def math_tex_fragment(job: MathRenderJob) -> str:
    if job.kind == "block":
        normalized = "\n".join(line.strip() for line in job.tex_body.splitlines() if line.strip())
        return (
            "$\\displaystyle\n"
            "\\begin{array}{l}\n"
            f"{normalized}\n"
            "\\end{array}$\n"
        )
    if job.kind == "inline":
        return f"$\\mathstrut {job.tex_body}$\n"
    if job.kind == "display":
        return f"$\\displaystyle\\mathstrut {job.tex_body}$\n"
    raise RuntimeError(f"unknown math render kind: {job.kind}")


def render_math_tex_to_pdf(tex_body: str, cache_dir: Path, color: Optional[Color] = None, packages: Optional[List[str]] = None) -> str:
    return ensure_math_pdf(make_math_job("block", tex_body, cache_dir, color, packages))


def render_inline_math_to_pdf(tex_body: str, cache_dir: Path, color: Optional[Color] = None, packages: Optional[List[str]] = None) -> str:
    return ensure_math_pdf(make_math_job("inline", tex_body, cache_dir, color, packages))


def render_display_math_to_pdf(tex_body: str, cache_dir: Path, color: Optional[Color] = None, packages: Optional[List[str]] = None) -> str:
    return ensure_math_pdf(make_math_job("display", tex_body, cache_dir, color, packages))


def canonical_latex_packages(packages: List[str]) -> List[str]:
    canonical: List[str] = []
    for raw in packages:
        name = str(raw)
        if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            raise RuntimeError(f"invalid LaTeX package name: {name}")
        if name not in canonical:
            canonical.append(name)
    return canonical


def latex_package_lines(packages: List[str]) -> str:
    return "".join(f"\\usepackage{{{package}}}\n" for package in packages)


def color_cache_key(color: Optional[Color]) -> str:
    if color is None:
        return "default"
    return ",".join(f"{max(0.0, min(1.0, component)):.6f}" for component in color)


def color_command(color: Optional[Color]) -> str:
    if color is None:
        return ""
    return "\\color[rgb]{" + color_cache_key(color) + "}\n"


def render_inline_icon_to_pdf(icon_ref: str, cache_dir: Path) -> str:
    digest = hashlib.sha256((FA_RENDER_VERSION + ":" + icon_ref).encode("utf-8")).hexdigest()[:16]
    work_dir = cache_dir / digest
    work_dir.mkdir(parents=True, exist_ok=True)
    svg_path = work_dir / "icon.svg"
    pdf_path = work_dir / "icon.pdf"
    if pdf_path.exists():
        touch_cache_entry(work_dir)
        touch_cache_entry(pdf_path)
        return str(pdf_path)
    svg_path.write_bytes(fetch_fontawesome_svg(icon_ref))
    run_checked(
        [
            rsvg_convert_bin(),
            "-f",
            "pdf",
            "-o",
            str(pdf_path),
            str(svg_path),
        ]
    )
    return str(pdf_path)


def render_svg_asset_to_pdf(source: str, cache_dir: Path) -> str:
    source_path = Path(source)
    digest = hashlib.sha256(
        (SVG_ASSET_RENDER_VERSION + ":" + str(source_path.resolve()) + ":").encode("utf-8")
        + source_path.read_bytes()
    ).hexdigest()[:16]
    work_dir = cache_dir / digest
    work_dir.mkdir(parents=True, exist_ok=True)
    pdf_path = work_dir / "asset.pdf"
    if pdf_path.exists():
        touch_cache_entry(work_dir)
        touch_cache_entry(pdf_path)
        return str(pdf_path)
    run_checked(
        [
            rsvg_convert_bin(),
            "-f",
            "pdf",
            "-o",
            str(pdf_path),
            str(source_path),
        ]
    )
    return str(pdf_path)


def is_svg_asset(path: str) -> bool:
    return Path(path).suffix.lower() == ".svg"


def rsvg_convert_bin() -> str:
    for candidate in (
        "rsvg-convert",
        "/opt/homebrew/bin/rsvg-convert",
        "/usr/local/bin/rsvg-convert",
        "/usr/bin/rsvg-convert",
    ):
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
    raise RuntimeError("rsvg-convert is required to render SVG assets")


# ---------------------------------------------------------------------------
# Layout helpers


def split_text_for_wrapping(text: str) -> List[str]:
    if not text:
        return []
    return re.findall(r"\s+|[A-Za-z0-9_./:+\-]+|.", text, flags=re.UNICODE)


def wrap_atoms(atoms: List[dict], max_width: float) -> List[List[dict]]:
    if not atoms:
        return [[]]
    if max_width <= 0:
        return [trim_trailing_space_atoms(atoms)]

    lines: List[List[dict]] = []
    current: List[dict] = []
    current_width = 0.0

    for atom in atoms:
        is_space = bool(atom.get("is_space"))
        atom_width = float(atom.get("width", 0.0))
        if is_space and not current:
            continue
        if current and current_width + atom_width > max_width:
            trimmed = trim_trailing_space_atoms(current)
            if trimmed:
                lines.append(trimmed)
                current = []
                current_width = 0.0
                if is_space:
                    continue
            elif not is_space:
                lines.append([atom])
                continue
        if is_space and not current:
            continue
        current.append(atom)
        current_width += atom_width

    trimmed = trim_trailing_space_atoms(current)
    if trimmed or not lines:
        lines.append(trimmed)
    return lines


def trim_trailing_space_atoms(atoms: List[dict]) -> List[dict]:
    trimmed = list(atoms)
    while trimmed and trimmed[-1].get("is_space"):
        trimmed.pop()
    return trimmed


def prefix_first_paragraph(blocks: List[dict], prefix: str) -> List[dict]:
    if not blocks:
        return [{"kind": "paragraph", "lines": [[{"kind": "text", "text": prefix}]]}]
    prefixed: List[dict] = []
    used = False
    for block in blocks:
        if not used and isinstance(block, dict) and block.get("kind") == "paragraph":
            lines = inline_lines_from_lines_field(block)
            first_line = list(lines[0]) if lines else []
            first_line.insert(0, {"kind": "text", "text": prefix})
            new_lines = [first_line] + [list(line) for line in lines[1:]]
            prefixed.append({"kind": "paragraph", "lines": new_lines})
            used = True
        else:
            prefixed.append(block)
    if not used:
        prefixed.insert(0, {"kind": "paragraph", "lines": [[{"kind": "text", "text": prefix}]]})
    return prefixed


# ---------------------------------------------------------------------------
# Highlighter


def load_highlighted_code_lines(spec: HighlighterSpec, text: str, cache_dir: Path) -> List[List[dict]]:
    script_hash = hashlib.sha256(spec.script_path.read_bytes()).hexdigest()
    digest = hashlib.sha256(
        (
            HIGHLIGHT_RENDER_VERSION
            + "\0"
            + spec.language
            + "\0"
            + script_hash
            + "\0"
            + text
        ).encode("utf-8")
    ).hexdigest()[:20]
    cache_path = cache_dir / f"{digest}.json"
    if cache_path.exists():
        touch_cache_entry(cache_path)
        payload = json.loads(cache_path.read_text(encoding="utf-8"))
        return payload.get("lines", [])

    payload_text = run_checked_capture(spec.argv(), input_text=text)
    payload = json.loads(payload_text)
    lines = payload.get("lines")
    if not isinstance(lines, list):
        raise RuntimeError(f"invalid highlighter output for language {spec.language}")
    cache_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return lines


def highlight_segment_color(token_class: str, default_rgb: Color, code_info: dict) -> Color:
    if token_class == "keyword":
        color = code_info.get("keyword_color")
        return parse_color_array(color) if color is not None else DEFAULT_CODE_KEYWORD
    if token_class == "comment":
        color = code_info.get("comment_color")
        return parse_color_array(color) if color is not None else DEFAULT_CODE_COMMENT
    if token_class == "string":
        color = code_info.get("string_color")
        return parse_color_array(color) if color is not None else DEFAULT_CODE_STRING
    return default_rgb


def parse_fontawesome_ref(icon_ref: str) -> Tuple[List[str], str]:
    if ":" not in icon_ref:
        raise RuntimeError(f"invalid Font Awesome icon reference: {icon_ref}")
    family, icon_name = icon_ref.split(":", 1)
    family = family.strip()
    icon_name = icon_name.strip()
    if not icon_name:
        raise RuntimeError(f"invalid Font Awesome icon reference: {icon_ref}")
    family_map = {
        "fa": ["brands", "solid", "regular"],
        "fab": ["brands"],
        "fas": ["solid"],
        "far": ["regular"],
        "fa-brands": ["brands"],
        "fa-solid": ["solid"],
        "fa-regular": ["regular"],
    }
    if family not in family_map:
        raise RuntimeError(f"unsupported Font Awesome icon family: {family}")
    return family_map[family], icon_name


def fetch_fontawesome_svg(icon_ref: str) -> bytes:
    style_keys, icon_name = parse_fontawesome_ref(icon_ref)
    attempted: List[str] = []
    for style_key in style_keys:
        url = f"https://raw.githubusercontent.com/FortAwesome/Font-Awesome/6.x/svgs/{style_key}/{icon_name}.svg"
        attempted.append(url)
        try:
            with urllib.request.urlopen(url) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                continue
            raise RuntimeError(f"failed to fetch Font Awesome icon {icon_ref}: {exc}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"failed to fetch Font Awesome icon {icon_ref}: {exc}") from exc
    raise RuntimeError(
        "Font Awesome icon not found: "
        f"{icon_ref}\ntried:\n" + "\n".join(f"  - {url}" for url in attempted)
    )


def code_highlighter_spec(render: dict) -> Optional[HighlighterSpec]:
    language = render_code_section(render).get("language")
    if not language:
        return None
    return CODE_HIGHLIGHTERS.get(str(language))


# ---------------------------------------------------------------------------
# Render policy access helpers (mirror the Zig core JSON shape)


def text_spec(render: dict, node: Optional[dict] = None) -> TextPaintSpec:
    text = render_text_section(render)
    return TextPaintSpec(
        font_name=str(text["font"]),
        bold_font_name=str(text["bold_font"]),
        italic_font_name=str(text["italic_font"]),
        code_font_name=str(text["code_font"]),
        font_size=float(text["font_size"]),
        color=parse_color_array(text["color"]),
        line_height=float(text["line_height"]),
        link_color=parse_color_array(text["link_color"]),
        link_underline_width=float(text["link_underline_width"]),
        link_underline_offset=float(text["link_underline_offset"]),
        inline_math_height_factor=float(text["inline_math_height_factor"]),
        inline_math_spacing=float(text["inline_math_spacing"]),
        markdown_block_gap=float(text["markdown_block_gap"]),
        markdown_list_inset=float(text.get("markdown_list_inset", 0.0)),
        markdown_list_indent=float(text["markdown_list_indent"]),
        markdown_code_font_size=float(text["markdown_code_font_size"]),
        markdown_code_line_height=float(text["markdown_code_line_height"]),
        markdown_code_pad_x=float(text["markdown_code_pad_x"]),
        markdown_code_pad_y=float(text["markdown_code_pad_y"]),
        markdown_code_fill=parse_optional_color_array(text.get("markdown_code_fill")),
        markdown_code_stroke=parse_optional_color_array(text.get("markdown_code_stroke")),
        markdown_code_line_width=float(text["markdown_code_line_width"]),
        markdown_code_radius=float(text["markdown_code_radius"]),
        cjk_bold_passes=int(text.get("cjk_bold_passes", 1)),
        cjk_bold_dx=float(text.get("cjk_bold_dx", 0.0)),
        math_latex_packages=math_packages_for_node(node or {}),
    )


def math_packages_for_node(node: dict) -> List[str]:
    render_env = node.get("render_env")
    if not isinstance(render_env, dict):
        return []
    math = render_env.get("math")
    if not isinstance(math, dict):
        return []
    latex = math.get("latex")
    if not isinstance(latex, dict):
        return []
    packages = latex.get("packages")
    if not isinstance(packages, list):
        return []
    return canonical_latex_packages([str(package) for package in packages])


def node_render(node: dict) -> dict:
    render = node.get("render")
    if not isinstance(render, dict):
        raise RuntimeError(f"node {node.get('id')} is missing resolved render policy")
    return render


def render_text_section(render: dict) -> dict:
    text = render.get("text")
    if not isinstance(text, dict):
        raise RuntimeError("render.text is required for text-like nodes")
    return text


def render_code_section(render: dict) -> dict:
    code = render.get("code")
    return code if isinstance(code, dict) else {}


def render_chrome_section(render: dict) -> dict:
    chrome = render.get("chrome")
    return chrome if isinstance(chrome, dict) else {}


def render_underline_section(render: dict) -> dict:
    underline = render.get("underline")
    return underline if isinstance(underline, dict) else {}


def render_rule_section(render: dict) -> dict:
    rule = render.get("rule")
    return rule if isinstance(rule, dict) else {}


def inline_lines_for_node(node: dict) -> List[List[dict]]:
    lines = node.get("inline_lines")
    if not isinstance(lines, list):
        raise RuntimeError(f"node {node.get('id')} is missing inline_lines")
    normalized: List[List[dict]] = []
    for line in lines:
        if not isinstance(line, list):
            raise RuntimeError(f"node {node.get('id')} has malformed inline_lines")
        normalized.append([segment for segment in line if isinstance(segment, dict)])
    return normalized


def inline_lines_from_lines_field(block: dict) -> List[List[dict]]:
    lines = block.get("lines")
    if not isinstance(lines, list):
        return [[]]
    normalized: List[List[dict]] = []
    for line in lines:
        if not isinstance(line, list):
            continue
        normalized.append([segment for segment in line if isinstance(segment, dict)])
    return normalized or [[]]


def display_math_text_from_lines(lines: List[List[dict]]) -> Optional[str]:
    chunks: List[str] = []
    saw_display_math = False
    for line_index, line in enumerate(lines):
        if line_index > 0:
            chunks.append("\n")
        for segment in line:
            kind = str(segment.get("kind", "text"))
            text = str(segment.get("text", ""))
            if kind == "display_math":
                saw_display_math = True
                chunks.append(text)
            elif text.strip():
                return None
            else:
                chunks.append(text)
    if not saw_display_math:
        return None
    tex_body = "".join(chunks).strip()
    return tex_body or None


def code_plain_lines_from_block(block: dict) -> List[str]:
    lines: List[str] = []
    for line in inline_lines_from_lines_field(block):
        chunks: List[str] = [str(segment.get("text", "")) for segment in line if isinstance(segment, dict)]
        text = "".join(chunks)
        pieces = text.split("\n")
        if pieces and pieces[-1] == "":
            pieces = pieces[:-1]
        lines.extend(pieces or [""])
    return lines or [""]


def markdown_blocks_for_node(node: dict) -> Optional[List[dict]]:
    blocks = node.get("blocks")
    if not isinstance(blocks, list):
        return None
    return [block for block in blocks if isinstance(block, dict)]


def parse_color_array(value: object) -> Color:
    if not isinstance(value, list) or len(value) != 3:
        raise RuntimeError(f"expected RGB color array, got {value!r}")
    return (float(value[0]), float(value[1]), float(value[2]))


def parse_optional_color_array(value: object) -> Optional[Color]:
    if value is None:
        return None
    return parse_color_array(value)


def node_property(node: dict, key: str) -> Optional[str]:
    properties = node.get("properties")
    if not isinstance(properties, dict):
        return None
    value = properties.get(key)
    if not isinstance(value, str) or value == "":
        return None
    return value


def background_color_for_page(page_node: dict, document_node: dict) -> Optional[Color]:
    return parse_optional_color_property(
        node_property(page_node, "background_fill") or node_property(document_node, "background_fill")
    )


def parse_optional_color_property(value: Optional[str]) -> Optional[Color]:
    if value is None:
        return None
    parts = [part.strip() for part in value.split(",")]
    if len(parts) != 3:
        raise RuntimeError(f"expected RGB color property, got {value!r}")
    return (float(parts[0]), float(parts[1]), float(parts[2]))


def parse_dash_array(value: object) -> Optional[Tuple[float, float]]:
    if value is None:
        return None
    if not isinstance(value, list) or len(value) != 2:
        raise RuntimeError(f"expected dash array, got {value!r}")
    return (float(value[0]), float(value[1]))


def resolve_alias(font_name: str) -> Tuple[str, str]:
    return FONT_ALIAS.get(font_name, ("body", ""))


def should_synthesize_cjk_bold(text: str, family: str, style: str, passes: int) -> bool:
    if passes <= 1:
        return False
    if family != "body" or "B" not in style:
        return False
    return any(ord(ch) >= 128 for ch in text)


def rgb_to_bytes(rgb: Color) -> Tuple[int, int, int]:
    return (
        max(0, min(255, int(round(rgb[0] * 255)))),
        max(0, min(255, int(round(rgb[1] * 255)))),
        max(0, min(255, int(round(rgb[2] * 255)))),
    )


# ---------------------------------------------------------------------------
# Asset / size helpers


def resolve_asset_path(base_dir: str, rel_path: str) -> str:
    path = Path(rel_path)
    if path.is_absolute():
        return str(path)
    return str(Path(base_dir) / path)


def fit_size(width: float, height: float, max_width: float, max_height: float) -> Tuple[float, float]:
    if width <= 0 or height <= 0:
        return max_width, max_height
    scale = min(max_width / width, max_height / height)
    return width * scale, height * scale


def fit_math_block_size(render: dict, width: float, height: float, max_width: float, max_height: float, source_text: str) -> Tuple[float, float]:
    if width <= 0 or height <= 0:
        return max_width, max_height
    math = render.get("math") or {}
    lines = max(1, len([line for line in source_text.splitlines() if line.strip()]))
    target_height = max(
        float(math.get("block_min_height", 30.0)),
        lines * float(math.get("block_line_height", 22.0)) + float(math.get("block_vertical_padding", 2.0)),
    ) * float(math.get("scale", 1.0))
    scale = min(max_width / width, max_height / height, target_height / height)
    return width * scale, height * scale


def pdf_page_size(path: str) -> Tuple[float, float]:
    page = PdfReader(path).pages[0]
    return float(page.mediabox.width), float(page.mediabox.height)


def image_size(path: str) -> Tuple[float, float]:
    with Image.open(path) as img:
        return float(img.width), float(img.height)


def run_checked_capture(argv: List[str], cwd: Optional[str] = None, input_text: Optional[str] = None) -> str:
    proc = subprocess.run(
        argv,
        cwd=cwd,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed: {' '.join(argv)}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    return proc.stdout


def run_checked(argv: List[str], cwd: Optional[str] = None) -> None:
    _ = run_checked_capture(argv, cwd=cwd)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
