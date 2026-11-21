#!/usr/bin/env python3
"""Select immutable release sources for VS Code extension publication."""
import argparse
import pathlib
import subprocess

from release_versions import parse_release_tag


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
    subprocess.run(["git", "-C", str(root), "checkout", "--detach", release_commit], check=True)
    print(f"Release source: {version.tag} ({release_commit})", flush=True)
    return release_commit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    prepare(root, args.tag)


if __name__ == "__main__":
    main()
