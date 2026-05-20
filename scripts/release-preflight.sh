#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"

version="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ -z "$version" ]]; then
  echo "VERSION is empty" >&2
  exit 1
fi

tag="${1:-${GITHUB_REF_NAME:-}}"
if [[ "$tag" == refs/tags/* ]]; then
  tag="${tag#refs/tags/}"
fi
if [[ "$tag" == v*.*.* ]]; then
  tag_version="${tag#v}"
  if [[ "$tag_version" != "$version" ]]; then
    echo "tag $tag does not match VERSION $version" >&2
    exit 1
  fi
fi

python3 - "$ROOT" "$version" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
version = sys.argv[2]

checks = []

def read_json(path):
    with (root / path).open(encoding="utf-8") as f:
        return json.load(f)

checks.append(("editor/vscode/package.json", read_json("editor/vscode/package.json")["version"]))
checks.append(("editor/vscode/package-lock.json", read_json("editor/vscode/package-lock.json")["packages"][""]["version"]))
checks.append(("tree-sitter-ss/package.json", read_json("tree-sitter-ss/package.json")["version"]))
checks.append(("tree-sitter-ss/package-lock.json", read_json("tree-sitter-ss/package-lock.json")["packages"][""]["version"]))
checks.append(("tree-sitter-ss/tree-sitter.json", read_json("tree-sitter-ss/tree-sitter.json")["metadata"]["version"]))

changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
if not re.search(rf"^## \[{re.escape(version)}\](?:\s|-)", changelog, re.MULTILINE):
    checks.append(("CHANGELOG.md", "missing"))

failed = False
for path, found in checks:
    if found != version:
        print(f"{path}: expected {version}, found {found}", file=sys.stderr)
        failed = True

if failed:
    sys.exit(1)

print(f"release metadata ok: {version}")
PY
