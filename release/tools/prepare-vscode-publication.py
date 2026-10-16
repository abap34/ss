#!/usr/bin/env python3
"""Select immutable release sources while retaining current completion validation."""
import argparse
import os
import pathlib
import subprocess

from release_versions import parse_release_tag


VALIDATION_FILES = (
    "tests/runtime/harness.mjs",
    "tests/runtime/lsp_completion_runtime_spec.mjs",
)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def prepare(root, tag):
    version = parse_release_tag(tag)
    if tag != version.tag:
        raise ValueError("use a canonical release tag such as v0.8.4")
    if version.is_patch_release:
        raise ValueError("Marketplace publication requires a normal release tag")
    if git(root, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("tracked files must be clean before selecting release sources")
    release_commit = git(root, "rev-parse", "--verify", f"refs/tags/{version.tag}^{{commit}}")
    validation_commit = git(root, "rev-parse", "HEAD")
    validation = {name: (root / name).read_bytes() for name in VALIDATION_FILES}
    # The original request deadline includes semantic analysis. Current tests
    # allow incomplete responses and still require complete, correct candidates.
    subprocess.run(["git", "-C", str(root), "checkout", "--detach", release_commit], check=True)
    for name, content in validation.items():
        (root / name).write_bytes(content)
    print(f"Release source: {version.tag} ({release_commit})", flush=True)
    print(f"Completion validation: {validation_commit}", flush=True)
    return release_commit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    commit = prepare(root, args.tag)
    if environment_file := os.environ.get("GITHUB_ENV"):
        with open(environment_file, "a") as stream:
            stream.write(f"RELEASE_COMMIT={commit}\n")


if __name__ == "__main__":
    main()
