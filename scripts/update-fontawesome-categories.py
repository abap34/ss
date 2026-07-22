#!/usr/bin/env python3
"""Generate the editor category catalog from official Font Awesome metadata."""

from __future__ import annotations

import argparse
import difflib
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
FONT_AWESOME_ROOT = ROOT / "third_party" / "fontawesome-free"
DEFAULT_OUTPUT = FONT_AWESOME_ROOT / "metadata" / "categories.zig"
SPRITES = (
    FONT_AWESOME_ROOT / "sprites" / "solid.svg",
    FONT_AWESOME_ROOT / "sprites" / "regular.svg",
    FONT_AWESOME_ROOT / "sprites" / "brands.svg",
)
VERSION_PATTERN = re.compile(r"Font Awesome Free ([0-9]+(?:\.[0-9]+)*) ")
IDENTIFIER_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")
UPSTREAM_TEMPLATE = (
    "https://raw.githubusercontent.com/FortAwesome/Font-Awesome/"
    "{version}/metadata/categories.yml"
)


class MetadataError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when the checked-in generated file differs",
    )
    parser.add_argument(
        "--source",
        type=Path,
        help="read YAML from a local file instead of the official release",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="generated Zig file",
    )
    return parser.parse_args()


def sprite_version(path: Path) -> str:
    prefix = path.read_text(encoding="utf-8")[:4096]
    match = VERSION_PATTERN.search(prefix)
    if match is None:
        raise MetadataError(f"Font Awesome version is missing from {path}")
    return match.group(1)


def available_icons(paths: tuple[Path, ...]) -> set[str]:
    names: set[str] = set()
    for path in paths:
        for _, element in ET.iterparse(path, events=("start",)):
            if element.tag.rsplit("}", 1)[-1] != "symbol":
                continue
            name = element.attrib.get("id")
            if name is None or IDENTIFIER_PATTERN.fullmatch(name) is None:
                raise MetadataError(f"invalid symbol id in {path}: {name!r}")
            names.add(name)
    if not names:
        raise MetadataError("Font Awesome sprites contain no symbols")
    return names


def load_yaml(source: Path | None, version: str) -> tuple[Any, str]:
    url = UPSTREAM_TEMPLATE.format(version=version)
    if source is not None:
        payload = source.read_bytes()
    else:
        request = urllib.request.Request(
            url,
            headers={"User-Agent": "ss-fontawesome-category-generator"},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
    return yaml.safe_load(payload), url


def normalize_categories(document: Any, icons: set[str]) -> list[dict[str, Any]]:
    if not isinstance(document, dict):
        raise MetadataError("categories.yml must contain a mapping")

    categories: list[dict[str, Any]] = []
    for category_id in sorted(document):
        entry = document[category_id]
        if not isinstance(category_id, str) or IDENTIFIER_PATTERN.fullmatch(category_id) is None:
            raise MetadataError(f"invalid category id: {category_id!r}")
        if not isinstance(entry, dict):
            raise MetadataError(f"category {category_id!r} must contain a mapping")
        if set(entry) != {"icons", "label"}:
            raise MetadataError(
                f"category {category_id!r} has unexpected fields: {sorted(entry)}"
            )
        label = entry["label"]
        source_icons = entry["icons"]
        if not isinstance(label, str) or not label.strip():
            raise MetadataError(f"category {category_id!r} has an invalid label")
        if not isinstance(source_icons, list):
            raise MetadataError(f"category {category_id!r} icons must be a sequence")

        seen: set[str] = set()
        category_icons: list[str] = []
        for name in source_icons:
            if not isinstance(name, str) or IDENTIFIER_PATTERN.fullmatch(name) is None:
                raise MetadataError(f"category {category_id!r} has invalid icon {name!r}")
            if name in seen:
                raise MetadataError(f"category {category_id!r} repeats icon {name!r}")
            seen.add(name)
            if name in icons:
                category_icons.append(name)
        if category_icons:
            categories.append(
                {"id": category_id, "label": label, "icons": category_icons}
            )

    if not categories:
        raise MetadataError("official metadata has no categories for bundled Free icons")
    return categories


def zig_string(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def render(version: str, url: str, categories: list[dict[str, Any]]) -> str:
    lines = [
        "// Generated by scripts/update-fontawesome-categories.py. Do not edit.",
        "",
        f"pub const upstream_version = {zig_string(version)};",
        f"pub const upstream_url = {zig_string(url)};",
        "",
        "pub const Category = struct {",
        "    id: []const u8,",
        "    label: []const u8,",
        "    icons: []const []const u8,",
        "};",
        "",
        "pub const categories: []const Category = &.{",
    ]
    for category in categories:
        lines.extend(
            [
                "    .{",
                f"        .id = {zig_string(category['id'])},",
                f"        .label = {zig_string(category['label'])},",
                "        .icons = &.{",
            ]
        )
        lines.extend(
            f"            {zig_string(name)}," for name in category["icons"]
        )
        lines.extend(["        },", "    },"])
    lines.extend(["};", ""])
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    versions = {sprite_version(path) for path in SPRITES}
    if len(versions) != 1:
        raise MetadataError(f"Font Awesome sprite versions differ: {sorted(versions)}")
    version = versions.pop()
    document, url = load_yaml(args.source, version)
    generated = render(
        version,
        url,
        normalize_categories(document, available_icons(SPRITES)),
    )

    if args.check:
        try:
            current = args.output.read_text(encoding="utf-8")
        except FileNotFoundError:
            current = ""
        if current == generated:
            print(f"Font Awesome {version} category catalog is current.")
            return 0
        sys.stderr.writelines(
            difflib.unified_diff(
                current.splitlines(keepends=True),
                generated.splitlines(keepends=True),
                fromfile=str(args.output),
                tofile="generated from official categories.yml",
            )
        )
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated, encoding="utf-8")
    print(f"Wrote {args.output} from Font Awesome {version} metadata.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (MetadataError, OSError, yaml.YAMLError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
