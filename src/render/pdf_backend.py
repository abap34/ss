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
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from fpdf import FPDF
from PIL import Image
from pypdf import PdfReader, PdfWriter, Transformation

PAGE_WIDTH = 1280.0
PAGE_HEIGHT = 720.0
REPO_ROOT = Path(__file__).resolve().parents[2]
FONT_DIR = REPO_ROOT / "third_party" / "fonts"
MATH_RENDER_VERSION = "v3"
HIGHLIGHT_RENDER_VERSION = "v1"
FA_RENDER_VERSION = "v1"

# Canonical fpdf2 family + style for each render-policy font name.
FONT_ALIAS: Dict[str, Tuple[str, str]] = {
    "Helvetica": ("body", ""),
    "Helvetica-Bold": ("body", "B"),
    "Helvetica-Oblique": ("body", "I"),
    "Helvetica-BoldOblique": ("body", "BI"),
    "Times-Roman": ("body", ""),
    "Times-Bold": ("body", "B"),
    "Times-Italic": ("body", "I"),
    "Times-BoldItalic": ("body", "BI"),
    "Courier": ("mono", ""),
    "Courier-Bold": ("mono", "B"),
    "Courier-Oblique": ("mono", "I"),
    "Courier-BoldOblique": ("mono", "BI"),
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


@dataclass(frozen=True)
class HighlighterSpec:
    language: str
    script_path: Path

    def argv(self) -> List[str]:
        return [sys.executable, str(self.script_path), "--language", self.language]


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

    math_cache_dir = Path(".ss-cache") / "math"
    math_cache_dir.mkdir(parents=True, exist_ok=True)
    highlight_cache_dir = Path(".ss-cache") / "highlight"
    highlight_cache_dir.mkdir(parents=True, exist_ok=True)
    icon_cache_dir = Path(".ss-cache") / "icons"
    icon_cache_dir.mkdir(parents=True, exist_ok=True)
    temp_base = Path(".ss-cache") / "render"
    temp_base.mkdir(parents=True, exist_ok=True)
    base_pdf = temp_base / (Path(output_pdf).stem + ".base.pdf")

    renderer = Renderer(asset_base_dir, math_cache_dir, highlight_cache_dir, icon_cache_dir)
    overlays_by_page = renderer.render(doc, str(base_pdf))
    merge_overlays(str(base_pdf), output_pdf, overlays_by_page)

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


# ---------------------------------------------------------------------------
# Renderer


class Renderer:
    def __init__(self, asset_base_dir: str, math_cache_dir: Path, highlight_cache_dir: Path, icon_cache_dir: Path) -> None:
        self.asset_base_dir = asset_base_dir
        self.math_cache_dir = math_cache_dir
        self.highlight_cache_dir = highlight_cache_dir
        self.icon_cache_dir = icon_cache_dir
        self.pdf = FPDF(unit="pt", format=(PAGE_WIDTH, PAGE_HEIGHT))
        self.pdf.set_auto_page_break(auto=False)
        self.pdf.set_margins(0, 0, 0)
        self.pdf.c_margin = 0
        self._register_fonts()

    def _register_fonts(self) -> None:
        body_reg = FONT_DIR / "NotoSansJP-Regular.ttf"
        body_bold = FONT_DIR / "NotoSansJP-Bold.ttf"
        mono_reg = FONT_DIR / "NotoSansMono-Regular.ttf"
        mono_bold = FONT_DIR / "NotoSansMono-Bold.ttf"
        emoji = FONT_DIR / "NotoEmoji-Regular.ttf"

        registrations: List[Tuple[str, str, str]] = [
            ("body", "", str(body_reg)),
            ("body", "B", str(body_bold)),
            # NotoSansJP has no italic axis: reuse the matching weight so the
            # style switch at least picks the right weight.
            ("body", "I", str(body_reg)),
            ("body", "BI", str(body_bold)),
            ("mono", "", str(mono_reg)),
            ("mono", "B", str(mono_bold)),
            ("mono", "I", str(mono_reg)),
            ("mono", "BI", str(mono_bold)),
            ("emoji", "", str(emoji)),
            ("emoji", "B", str(emoji)),
            ("emoji", "I", str(emoji)),
            ("emoji", "BI", str(emoji)),
        ]
        # fontkey -> (family, style) so fallback resolution can map fpdf2's
        # internal id back to the family/style we passed to add_font.
        self._fontkey_to_family_style: Dict[str, Tuple[str, str]] = {}
        for family, style, fname in registrations:
            self.pdf.add_font(family, style, fname)
            self._fontkey_to_family_style[family + style] = (family, style)

        self.pdf.set_fallback_fonts(["body", "emoji"], exact_match=False)

    # -- font run resolution (fpdf2's pdf.text() does not honour set_fallback_fonts;
    #    only cell()/write() do. We split each run into per-font segments so we can
    #    keep using pdf.text() for precise positioning while still getting CJK +
    #    emoji coverage from the registered fallback chain.) --

    def _resolve_font_for_char(self, char: str, family: str, style: str) -> Tuple[str, str]:
        primary_key = self._font_key(family, style)
        primary = self.pdf.fonts.get(primary_key)
        if primary is not None and ord(char) in primary.cmap:
            return family, style
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
        overlays_by_page: Dict[int, List[Overlay]] = {}

        for page_index, page_id in enumerate(doc["page_order"]):
            self.pdf.add_page()
            page_overlays: List[Overlay] = []
            for child_id in children_by_parent.get(page_id, []):
                node = node_by_id.get(child_id)
                if node is None:
                    continue
                page_overlays.extend(self._render_node(node))
            overlays_by_page[page_index] = page_overlays

        self.pdf.output(output_pdf)
        return overlays_by_page

    def _render_node(self, node: dict) -> List[Overlay]:
        render = node_render(node)
        x = float(node.get("x") or 0.0)
        y = float(node.get("y") or 0.0)
        width = float(node.get("width") or 0.0)
        height = float(node.get("height") or 0.0)

        self._draw_node_chrome(render, x, y, width, height)
        kind = render.get("kind")
        content = node.get("content") or ""

        if kind == "chrome_only":
            return []
        if kind == "text":
            return self._render_text_node(render, x, y, width, height, node)
        if kind == "vector_math":
            return self._render_vector_math(render, x, y, width, height, content)
        if kind == "vector_asset":
            return self._render_vector_asset(x, y, width, height, content)
        if kind == "raster_asset":
            self._render_raster_asset(x, y, width, height, content)
            return []
        if kind == "code":
            self._render_code_node(render, x, y, width, height, content)
            return []
        raise RuntimeError(f"unknown render kind: {kind}")

    # -- chrome --

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
            top_y = self.to_tl(y + height)
            self._set_fill(fill if fill is not None else (1.0, 1.0, 1.0))
            self._set_stroke(stroke if stroke is not None else (0.0, 0.0, 0.0))
            self.pdf.set_line_width(line_width)
            style = ""
            if fill is not None:
                style += "F"
            if stroke is not None:
                style += "D"
            self.pdf.rect(
                x,
                top_y,
                width,
                height,
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
        spec = text_spec(render)
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
                for item_index, item in enumerate(items):
                    item_blocks = item.get("blocks", []) if isinstance(item, dict) else []
                    marker = self._list_marker(kind, list_depth, start + item_index)
                    item_overlays, cursor_bl = self._draw_list_item(
                        spec,
                        x,
                        cursor_bl,
                        item_blocks,
                        max_width,
                        marker,
                        list_depth,
                    )
                    overlays.extend(item_overlays)
                    if item_index != len(items) - 1:
                        cursor_bl -= spec.markdown_block_gap
            if index != len(blocks) - 1:
                cursor_bl -= spec.markdown_block_gap
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

        cursor_bl = baseline_bl
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
                cursor_bl -= spec.markdown_block_gap

        return overlays, cursor_bl

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
        return overlays, box_bottom - pad_y

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
        pdf_path = render_inline_math_to_pdf(tex_body, self.math_cache_dir)
        src_w, src_h = pdf_page_size(pdf_path)
        target_h = spec.line_height
        target_w = src_w * (target_h / src_h) if src_h > 0 else max_width
        if target_w > max_width and target_w > 0:
            scale = max_width / target_w
            target_w *= scale
            target_h *= scale
        return [
            Overlay(
                pdf_path,
                x,
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
                self.pdf.link(x, rect_top, width, rect_h, link=url)

    def _layout_atoms(self, line: List[dict], spec: TextPaintSpec) -> List[dict]:
        atoms: List[dict] = []
        for run in line:
            kind = str(run.get("kind", "text"))
            segment = str(run.get("text", ""))
            if kind in ("math", "display_math"):
                pdf_path = render_inline_math_to_pdf(segment, self.math_cache_dir)
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
    ) -> List[Overlay]:
        pdf_path = render_math_tex_to_pdf(content, self.math_cache_dir)
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
    ) -> None:
        source = resolve_asset_path(self.asset_base_dir, content)
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


# ---------------------------------------------------------------------------
# Overlay merge


def merge_overlays(base_pdf: str, output_pdf: str, overlays_by_page: Dict[int, List[Overlay]]) -> None:
    reader = PdfReader(base_pdf)
    writer = PdfWriter()

    for index, page in enumerate(reader.pages):
        overlays = overlays_by_page.get(index, [])
        for overlay in overlays:
            src_reader = PdfReader(overlay.pdf_path)
            src_page = src_reader.pages[0]
            left = float(src_page.mediabox.left)
            bottom = float(src_page.mediabox.bottom)
            width = float(src_page.mediabox.width)
            height = float(src_page.mediabox.height)
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
# Math (LaTeX -> PDF)


def render_math_tex_to_pdf(tex_body: str, cache_dir: Path) -> str:
    digest = hashlib.sha256((MATH_RENDER_VERSION + ":block:" + tex_body).encode("utf-8")).hexdigest()[:16]
    work_dir = cache_dir / digest
    work_dir.mkdir(parents=True, exist_ok=True)
    tex_path = work_dir / "main.tex"
    pdf_path = work_dir / "main.pdf"
    if pdf_path.exists():
        return str(pdf_path)
    normalized = "\n".join(line.strip() for line in tex_body.splitlines() if line.strip())
    tex_path.write_text(
        "\\documentclass[border=0pt]{standalone}\n"
        "\\usepackage{amsmath,amssymb}\n"
        "\\begin{document}\n"
        "$\\displaystyle\n"
        "\\begin{array}{l}\n"
        f"{normalized}\n"
        "\\end{array}$\n"
        "\\end{document}\n",
        encoding="utf-8",
    )
    run_checked(["pdflatex", "-interaction=nonstopmode", "-halt-on-error", "main.tex"], cwd=str(work_dir))
    return str(pdf_path)


def render_inline_math_to_pdf(tex_body: str, cache_dir: Path) -> str:
    digest = hashlib.sha256((MATH_RENDER_VERSION + ":inline:" + tex_body).encode("utf-8")).hexdigest()[:16]
    work_dir = cache_dir / digest
    work_dir.mkdir(parents=True, exist_ok=True)
    tex_path = work_dir / "main.tex"
    pdf_path = work_dir / "main.pdf"
    if pdf_path.exists():
        return str(pdf_path)
    tex_path.write_text(
        "\\documentclass[border=0pt]{standalone}\n"
        "\\usepackage{amsmath,amssymb}\n"
        "\\begin{document}\n"
        f"$\\mathstrut {tex_body}$\n"
        "\\end{document}\n",
        encoding="utf-8",
    )
    run_checked(["pdflatex", "-interaction=nonstopmode", "-halt-on-error", "main.tex"], cwd=str(work_dir))
    return str(pdf_path)


def render_inline_icon_to_pdf(icon_ref: str, cache_dir: Path) -> str:
    digest = hashlib.sha256((FA_RENDER_VERSION + ":" + icon_ref).encode("utf-8")).hexdigest()[:16]
    work_dir = cache_dir / digest
    work_dir.mkdir(parents=True, exist_ok=True)
    svg_path = work_dir / "icon.svg"
    pdf_path = work_dir / "icon.pdf"
    if pdf_path.exists():
        return str(pdf_path)
    svg_path.write_bytes(fetch_fontawesome_svg(icon_ref))
    run_checked(
        [
            "/opt/homebrew/bin/rsvg-convert",
            "-f",
            "pdf",
            "-o",
            str(pdf_path),
            str(svg_path),
        ]
    )
    return str(pdf_path)


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


def text_spec(render: dict) -> TextPaintSpec:
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
    )


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
    )
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
