#!/usr/bin/env python3
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys
from typing import List, Optional

from release_versions import (
    parse_release_tag,
    require_release_tag,
    supported_version_hint,
)


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


def generated_patch_changelog(root: pathlib.Path, from_tag: str, cherry_picks: List[str]) -> str:
    bullets: list[str] = []
    for commit in cherry_picks:
        subject = git(root, "show", "-s", "--format=%s", commit, capture=True)
        short = git(root, "rev-parse", "--short", commit, capture=True)
        bullets.append(f"- Backported {punctuate(subject)} ({short})")
    if not bullets:
        bullets.append(f"- Prepared a patch release for users staying on {from_tag}.")
    intro = f"This patch release is based on {from_tag} and includes only the selected backports."
    return f"{intro}\n\n### Fixed\n\n" + "\n".join(bullets)


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
    parser.add_argument("tag", help=f"Release tag, for example {supported_version_hint()}.")
    parser.add_argument("--base", help="Implementation commit to release. Defaults to HEAD.")
    parser.add_argument("--from-tag", help="Released tag to use as the base for a patch release worktree.")
    parser.add_argument(
        "--cherry-pick",
        action="append",
        default=[],
        help="Commit to cherry-pick onto --from-tag before preparing patch release metadata. May be repeated.",
    )
    parser.add_argument("--branch", help="Release branch to create. Defaults to release/<tag>.")
    parser.add_argument("--detached", action="store_true", help="Create a detached worktree instead of a branch.")
    parser.add_argument("--worktree", type=pathlib.Path, help="Worktree path. Defaults under .ss-cache/release-worktrees/.")
    parser.add_argument("--date", default=datetime.date.today().isoformat(), help="Changelog date. Defaults to today.")
    parser.add_argument("--previous-tag", help="Previous release tag used when drafting changelog entries.")
    parser.add_argument("--no-commit", action="store_true", help="Update files but leave the release commit to the caller.")
    args = parser.parse_args()

    try:
        tag_info = parse_release_tag(args.tag)
    except ValueError as err:
        raise SystemExit(str(err))
    tag = tag_info.tag
    version = tag_info.version
    root = repo_root()
    branch = None if args.detached else args.branch or f"release/{tag}"
    worktree = args.worktree.resolve() if args.worktree else default_worktree(root, tag)

    if args.detached and args.branch:
        raise SystemExit("--branch cannot be used with --detached")
    if args.from_tag and args.base:
        raise SystemExit("--from-tag cannot be combined with --base")
    if args.cherry_pick and not args.from_tag:
        raise SystemExit("--cherry-pick requires --from-tag")
    if args.from_tag and not tag_info.is_patch_release:
        raise SystemExit("--from-tag is only supported for vX.Y.Z-patch.N releases")
    ensure_no_existing_tag(root, tag)

    source_base_tag = None
    source_base_commit = None
    release_base = None
    previous = None
    if args.from_tag:
        try:
            source_base_tag = require_release_tag(args.from_tag)
        except ValueError as err:
            raise SystemExit(str(err))
        source_base_commit = git(root, "rev-parse", "--verify", f"{source_base_tag}^{{commit}}", capture=True)
        create_worktree(root, worktree, source_base_commit, branch)
        for commit in args.cherry_pick:
            run(["git", "cherry-pick", "-x", commit], worktree)
        release_base = git(worktree, "rev-parse", "HEAD", capture=True)
        changelog_body = generated_patch_changelog(root, source_base_tag, args.cherry_pick)
    else:
        base_ref = args.base or "HEAD"
        release_base = git(root, "rev-parse", "--verify", f"{base_ref}^{{commit}}", capture=True)
        previous = previous_tag(root, release_base, args.previous_tag)
        changelog_body = generated_changelog(root, previous, release_base)
        create_worktree(root, worktree, release_base, branch)

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
    print(f"release base: {release_base}")
    if source_base_tag is not None and source_base_commit is not None:
        print(f"source base: {source_base_tag} ({source_base_commit})")
    for commit in args.cherry_pick:
        print(f"cherry-picked: {commit}")
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
        print(f"  test \"$(git rev-parse HEAD^)\" = \"{release_base}\"")
        print(f"  release/tools/pre-release-check.sh --release-metadata-only --base {release_base} {tag}")
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
