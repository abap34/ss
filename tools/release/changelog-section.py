#!/usr/bin/env python3
import pathlib
import re
import sys

if len(sys.argv) != 2:
    print("usage: changelog-section.py <version-or-tag>", file=sys.stderr)
    sys.exit(2)

version = sys.argv[1]
if version.startswith("refs/tags/"):
    version = version.removeprefix("refs/tags/")
if version.startswith("v"):
    version = version[1:]

root = pathlib.Path(__file__).resolve().parents[2]
changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
pattern = re.compile(
    rf"^## \[{re.escape(version)}\][^\n]*\n(?P<body>.*?)(?=^## \[|\Z)",
    re.MULTILINE | re.DOTALL,
)
match = pattern.search(changelog)
if not match:
    print(f"CHANGELOG.md has no section for {version}", file=sys.stderr)
    sys.exit(1)

body = match.group("body").strip()
if not body:
    print(f"CHANGELOG.md section for {version} is empty", file=sys.stderr)
    sys.exit(1)

print(body)
