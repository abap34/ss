#!/usr/bin/env python3
import json
import os
import pathlib
import re
import sys


def read_json(path: pathlib.Path):
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def normalize_tag(value: str) -> str:
    if value.startswith("refs/tags/"):
        value = value.removeprefix("refs/tags/")
    return value


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[2]
    version = (root / "release" / "VERSION").read_text(encoding="utf-8").strip()
    if not version:
        print("release/VERSION is empty", file=sys.stderr)
        return 1

    tag = normalize_tag(sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GITHUB_REF_NAME", ""))
    if re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        tag_version = tag.removeprefix("v")
        if tag_version != version:
            print(f"tag {tag} does not match release/VERSION {version}", file=sys.stderr)
            return 1

    checks = [
        ("editor/vscode/package.json", read_json(root / "editor/vscode/package.json")["version"]),
        ("editor/vscode/package-lock.json", read_json(root / "editor/vscode/package-lock.json")["packages"][""]["version"]),
        ("editor/tree-sitter-ss/package.json", read_json(root / "editor/tree-sitter-ss/package.json")["version"]),
        ("editor/tree-sitter-ss/package-lock.json", read_json(root / "editor/tree-sitter-ss/package-lock.json")["packages"][""]["version"]),
        ("editor/tree-sitter-ss/tree-sitter.json", read_json(root / "editor/tree-sitter-ss/tree-sitter.json")["metadata"]["version"]),
    ]

    changelog = (root / "release" / "CHANGELOG.md").read_text(encoding="utf-8")
    if not re.search(rf"^## \[{re.escape(version)}\](?:\s|-)", changelog, re.MULTILINE):
        checks.append(("release/CHANGELOG.md", "missing"))

    failed = False
    for path, found in checks:
        if found != version:
            print(f"{path}: expected {version}, found {found}", file=sys.stderr)
            failed = True

    if failed:
        return 1

    print(f"release metadata ok: {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
