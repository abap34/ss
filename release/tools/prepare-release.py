#!/usr/bin/env python3
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys
from typing import List, Optional


METADATA_PATHS = [
    "release/VERSION",
    "release/CHANGELOG.md",
    "editor/vscode/package.json",
    "editor/vscode/package-lock.json",
    "editor/tree-sitter-ss/package.json",
    "editor/tree-sitter-ss/package-lock.json",
    "editor/tree-sitter-ss/tree-sitter.json",
]


def run(args, cwd: pathlib.Path, *, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(
        args,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        command = " ".join(str(arg) for arg in args)
        if capture and result.stderr:
            print(result.stderr, file=sys.stderr, end="")
        raise SystemExit(f"command failed: {command}")
    return result


def git(root: pathlib.Path, *args: str, capture: bool = False, check: bool = True) -> str:
    result = run(["git", *args], root, capture=capture, check=check)
    return result.stdout.strip() if capture else ""


def repo_root() -> pathlib.Path:
    result = run(["git", "rev-parse", "--show-toplevel"], pathlib.Path.cwd(), capture=True)
    return pathlib.Path(result.stdout.strip())


def normalize_tag(value: str) -> str:
    if value.startswith("refs/tags/"):
        value = value.removeprefix("refs/tags/")
    return value


def require_release_tag(tag: str) -> str:
    normalized = normalize_tag(tag)
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", normalized):
        raise SystemExit(f"release tag must look like v0.1.0, got {tag}")
    return normalized


def release_version(tag: str) -> str:
    return tag.removeprefix("v")


def default_worktree(root: pathlib.Path, tag: str) -> pathlib.Path:
    return root / ".ss-cache" / "release-worktrees" / tag


def ensure_no_existing_tag(root: pathlib.Path, tag: str) -> None:
    result = run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"], root, capture=True, check=False)
    if result.returncode == 0:
        raise SystemExit(f"local tag already exists: {tag}")


def ensure_branch_available(root: pathlib.Path, branch: str) -> None:
    result = run(["git", "rev-parse", "-q", "--verify", f"refs/heads/{branch}"], root, capture=True, check=False)
    if result.returncode == 0:
        raise SystemExit(f"local branch already exists: {branch}")


def read_json(path: pathlib.Path):
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def write_json(path: pathlib.Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def update_version_metadata(worktree: pathlib.Path, version: str) -> None:
    (worktree / "release" / "VERSION").write_text(f"{version}\n", encoding="utf-8")

    vscode_package = worktree / "editor" / "vscode" / "package.json"
    data = read_json(vscode_package)
    data["version"] = version
    write_json(vscode_package, data)

    vscode_lock = worktree / "editor" / "vscode" / "package-lock.json"
    data = read_json(vscode_lock)
    data["version"] = version
    data["packages"][""]["version"] = version
    write_json(vscode_lock, data)

    tree_sitter_package = worktree / "editor" / "tree-sitter-ss" / "package.json"
    data = read_json(tree_sitter_package)
    data["version"] = version
    write_json(tree_sitter_package, data)

    tree_sitter_lock = worktree / "editor" / "tree-sitter-ss" / "package-lock.json"
    data = read_json(tree_sitter_lock)
    data["version"] = version
    data["packages"][""]["version"] = version
    write_json(tree_sitter_lock, data)

    tree_sitter_json = worktree / "editor" / "tree-sitter-ss" / "tree-sitter.json"
    data = read_json(tree_sitter_json)
    data["metadata"]["version"] = version
    write_json(tree_sitter_json, data)


def previous_tag(root: pathlib.Path, base_commit: str, explicit: Optional[str]) -> Optional[str]:
    if explicit:
        return explicit
    result = run(
        ["git", "describe", "--tags", "--abbrev=0", f"{base_commit}^"],
        root,
        capture=True,
        check=False,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return None


def commit_subjects(root: pathlib.Path, previous: Optional[str], base_commit: str) -> List[str]:
    revision = f"{previous}..{base_commit}" if previous else base_commit
    output = git(root, "log", "--format=%s", "--reverse", revision, capture=True)
    return [line.strip() for line in output.splitlines() if line.strip()]


def punctuate(subject: str) -> str:
    if subject.endswith((".", "!", "?")):
        return subject
    return f"{subject}."


def generated_changelog(root: pathlib.Path, previous: Optional[str], base_commit: str) -> str:
    subjects = commit_subjects(root, previous, base_commit)
    if not subjects:
        return "### Changed\n\n- Prepared release metadata."
    bullets = "\n".join(f"- {punctuate(subject)}" for subject in subjects)
    return f"### Changed\n\n{bullets}"


def update_changelog(worktree: pathlib.Path, version: str, date: str, body: str) -> None:
    changelog_path = worktree / "release" / "CHANGELOG.md"
    text = changelog_path.read_text(encoding="utf-8")
    if re.search(rf"^## \[{re.escape(version)}\](?:\s|-)", text, re.MULTILINE):
        raise SystemExit(f"release/CHANGELOG.md already has a section for {version}")

    match = re.search(
        r"^## \[Unreleased\]\n(?P<body>.*?)(?=^## \[|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise SystemExit("release/CHANGELOG.md has no Unreleased section")

    unreleased_body = match.group("body").strip()
    release_body = unreleased_body if unreleased_body else body.strip()
    replacement = f"## [Unreleased]\n\n## [{version}] - {date}\n\n{release_body}\n\n"
    updated = text[: match.start()] + replacement + text[match.end() :].lstrip("\n")
    changelog_path.write_text(updated, encoding="utf-8")


def create_worktree(root: pathlib.Path, worktree: pathlib.Path, base_commit: str, branch: Optional[str]) -> None:
    if worktree.exists():
        raise SystemExit(f"worktree path already exists: {worktree}")
    worktree.parent.mkdir(parents=True, exist_ok=True)
    if branch:
        ensure_branch_available(root, branch)
        run(["git", "worktree", "add", "-b", branch, str(worktree), base_commit], root)
    else:
        run(["git", "worktree", "add", "--detach", str(worktree), base_commit], root)


def commit_release_metadata(worktree: pathlib.Path, tag: str) -> str:
    run(["git", "add", *METADATA_PATHS], worktree)
    run(
        [
            "git",
            "commit",
            "-m",
            f"chore: prepare {tag} release",
            "-m",
            "Co-authored-by: Codex <codex@openai.com>",
        ],
        worktree,
    )
    return git(worktree, "rev-parse", "HEAD", capture=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prepare release metadata from an arbitrary implementation commit in an isolated worktree."
    )
    parser.add_argument("tag", help="Release tag, for example v0.6.1.")
    parser.add_argument("--base", default="HEAD", help="Implementation commit to release. Defaults to HEAD.")
    parser.add_argument("--branch", help="Release branch to create. Defaults to release/<tag>.")
    parser.add_argument("--detached", action="store_true", help="Create a detached worktree instead of a branch.")
    parser.add_argument("--worktree", type=pathlib.Path, help="Worktree path. Defaults under .ss-cache/release-worktrees/.")
    parser.add_argument("--date", default=datetime.date.today().isoformat(), help="Changelog date. Defaults to today.")
    parser.add_argument("--previous-tag", help="Previous release tag used when drafting changelog entries.")
    parser.add_argument("--no-commit", action="store_true", help="Update files but leave the release commit to the caller.")
    args = parser.parse_args()

    tag = require_release_tag(args.tag)
    version = release_version(tag)
    root = repo_root()
    base_commit = git(root, "rev-parse", "--verify", f"{args.base}^{{commit}}", capture=True)
    branch = None if args.detached else args.branch or f"release/{tag}"
    worktree = args.worktree.resolve() if args.worktree else default_worktree(root, tag)

    if args.detached and args.branch:
        raise SystemExit("--branch cannot be used with --detached")
    ensure_no_existing_tag(root, tag)

    previous = previous_tag(root, base_commit, args.previous_tag)
    changelog_body = generated_changelog(root, previous, base_commit)

    create_worktree(root, worktree, base_commit, branch)
    update_version_metadata(worktree, version)
    update_changelog(worktree, version, args.date, changelog_body)

    run([str(worktree / "release" / "tools" / "preflight.py"), tag], worktree)
    run([str(worktree / "release" / "tools" / "changelog-section.py"), tag], worktree, capture=True)
    run(["git", "diff", "--check"], worktree)

    release_commit = None
    if not args.no_commit:
        release_commit = commit_release_metadata(worktree, tag)

    print()
    print(f"release tag: {tag}")
    print(f"release base: {base_commit}")
    if previous:
        print(f"previous tag: {previous}")
    print(f"worktree: {worktree}")
    if branch:
        print(f"branch: {branch}")
    else:
        print("branch: detached")
    if release_commit:
        print(f"release commit: {release_commit}")
    else:
        print("release commit: not created")
    print()
    print("Next commands:")
    print(f"  cd {worktree}")
    if release_commit:
        print(f"  test \"$(git rev-parse HEAD^)\" = \"{base_commit}\"")
        print(f"  release/tools/pre-release-check.sh --release-metadata-only {tag}")
        print(f"  git tag -a {tag} -m \"ss {tag}\"")
    else:
        print("  edit release/CHANGELOG.md if needed")
        print(f"  release/tools/preflight.py {tag}")
        print("  git diff --check")
        print(f"  git add {' '.join(METADATA_PATHS)}")
        print(f"  git commit -m \"chore: prepare {tag} release\"")
    return 0


if __name__ == "__main__":
    sys.exit(main())
