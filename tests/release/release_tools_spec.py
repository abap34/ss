#!/usr/bin/env python3
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "release" / "tools"))

from release_versions import (  # noqa: E402
    homebrew_formula_class,
    homebrew_formula_name,
    parse_release_tag,
    parse_version,
)


def assert_equal(left, right):
    if left != right:
        raise AssertionError(f"expected {right!r}, got {left!r}")


def assert_raises(fn):
    try:
        fn()
    except ValueError:
        return
    raise AssertionError("expected ValueError")


def test_release_version_parsing():
    normal = parse_release_tag("v0.7.2")
    assert_equal(normal.version, "0.7.2")
    assert_equal(normal.is_patch_release, False)

    patch = parse_release_tag("refs/tags/v0.7.1-patch.1")
    assert_equal(patch.version, "0.7.1-patch.1")
    assert_equal(patch.is_patch_release, True)
    assert_equal(patch.patch_release, 1)

    assert_raises(lambda: parse_version("0.7.1-patch.0"))
    assert_raises(lambda: parse_version("0.7.1-patch.01"))
    assert_raises(lambda: parse_version("0.7.1+patch.1"))


def test_homebrew_formula_names():
    assert_equal(homebrew_formula_name("0.7.2"), "ss")
    assert_equal(homebrew_formula_name("0.7.1-patch.1"), "ss@0.7.1-patch.1")
    assert_equal(homebrew_formula_class("ss"), "Ss")
    assert_equal(homebrew_formula_class("ss@0.7.1-patch.1"), "SsAT071Patch1")


def test_bundled_md4c():
    root = ROOT / "third_party" / "md4c"
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    assert_equal(manifest["schema"], 1)
    assert_equal(manifest["upstream"], "https://github.com/mity/md4c")
    assert_equal(manifest["version"], "0.5.3")
    assert_equal(manifest["tag"], "release-0.5.3")
    assert_equal(manifest["commit"], "472c417005c2c71b8617de4f7b8d6b30411d78f4")
    assert_equal(manifest["license"], "MIT")

    entries = manifest["files"]
    assert_equal(len(entries), 3)
    files = {entry["path"]: entry["sha256"] for entry in entries}
    assert_equal(set(files), {"LICENSE.md", "src/md4c.c", "src/md4c.h"})
    for relative_path, expected_sha256 in files.items():
        actual_sha256 = hashlib.sha256((root / relative_path).read_bytes()).hexdigest()
        assert_equal(actual_sha256, expected_sha256)


def test_render_homebrew_formula():
    with tempfile.TemporaryDirectory() as tmp:
        output = pathlib.Path(tmp) / "ss@0.7.1-patch.1.rb"
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "release" / "tools" / "render-homebrew-formula.py"),
                "--version",
                "0.7.1-patch.1",
                "--source-url",
                "https://example.com/ss-0.7.1-patch.1.tar.gz",
                "--source-sha256",
                "0" * 64,
                "--output",
                str(output),
            ],
            cwd=ROOT,
            check=True,
            timeout=30,
        )
        formula = output.read_text(encoding="utf-8")
        assert "class SsAT071Patch1 < Formula" in formula
        assert 'version "0.7.1-patch.1"' in formula
        assert 'url "https://example.com/ss-0.7.1-patch.1.tar.gz"' in formula
        assert 'resource "md4c"' not in formula
        assert "third_party/md4c" not in formula
        assert "codeload.github.com/mity/md4c" not in formula
        subprocess.run(["ruby", "-c", str(output)], check=True, timeout=30)


def main():
    test_release_version_parsing()
    test_homebrew_formula_names()
    test_bundled_md4c()
    test_render_homebrew_formula()


if __name__ == "__main__":
    main()
