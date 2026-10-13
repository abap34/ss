#!/usr/bin/env python3
"""Check or refresh the ss metadata for the MD4C subtree."""

import argparse
import hashlib
import json
import pathlib
import re
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[3]
MANIFEST = ROOT / "third_party" / "tools" / "md4c" / "manifest.json"
PREFIX = "third_party/md4c"
FILES = ("LICENSE.md", "src/md4c.c", "src/md4c.h")


def file_entries(root):
    return [
        {
            "path": path,
            "sha256": hashlib.sha256((root / PREFIX / path).read_bytes()).hexdigest(),
        }
        for path in FILES
    ]


def validate(manifest, root):
    if manifest.get("schema") != 2 or manifest.get("integration") != "git-subtree":
        raise ValueError("unsupported MD4C manifest schema or integration")
    if manifest.get("upstream") != "https://github.com/mity/md4c":
        raise ValueError("unexpected MD4C upstream repository")
    if manifest.get("license") != "MIT":
        raise ValueError("unexpected MD4C license")
    for field in ("version", "tag"):
        if not isinstance(manifest.get(field), str) or not manifest[field]:
            raise ValueError(f"missing MD4C upstream {field}")
    fork = manifest.get("fork", {})
    if fork.get("repository") != "https://github.com/abap34/md4c":
        raise ValueError("unexpected MD4C fork repository")
    if not isinstance(fork.get("branch"), str) or not fork["branch"]:
        raise ValueError("missing MD4C fork branch")
    for commit in (manifest.get("commit"), fork.get("imported_commit")):
        if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError("MD4C commits must be full 40-character object IDs")
    if manifest.get("files") != file_entries(root):
        raise ValueError("MD4C checksums differ; run python3 third_party/tools/md4c/metadata.py --refresh")
    if (root / PREFIX / "manifest.json").exists():
        raise ValueError("ss metadata must stay outside the MD4C subtree")


def imported_commit():
    history = subprocess.check_output(
        [
            "git", "log", "-1", "--format=%B",
            "--grep=^git-subtree-dir: third_party/md4c/*$",
        ],
        cwd=ROOT,
        text=True,
        timeout=30,
    )
    match = re.search(r"^git-subtree-split: ([0-9a-f]{40})$", history, re.MULTILINE)
    if match is None:
        raise ValueError("MD4C subtree import metadata was not found in Git history")
    return match[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="check the bundled files without network or Git access")
    mode.add_argument("--refresh", action="store_true", help="record the last subtree import and current file checksums")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if args.refresh:
        manifest["fork"]["imported_commit"] = imported_commit()
        manifest["files"] = file_entries(ROOT)
    validate(manifest, ROOT)
    if args.refresh:
        MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("MD4C subtree metadata is current")


if __name__ == "__main__":
    main()
