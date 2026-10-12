#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tarfile
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
    manifest = json.loads((ROOT / "third_party/md4c-manifest.json").read_text(encoding="utf-8"))
    assert_equal(manifest["schema"], 2)
    assert_equal(manifest["integration"], "git-subtree")
    assert_equal(manifest["upstream"], "https://github.com/mity/md4c")
    assert_equal(manifest["fork"]["repository"], "https://github.com/abap34/md4c")
    assert_equal(manifest["fork"]["branch"], "master")
    assert_equal(manifest["license"], "MIT")
    assert_equal((root / "manifest.json").exists(), False)

    spec = importlib.util.spec_from_file_location("md4c_metadata", ROOT / "scripts/md4c.py")
    metadata = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(metadata)
    metadata.validate(manifest, ROOT)
    assert_equal(metadata.imported_commit(), manifest["fork"]["imported_commit"])

    stale_hash = copy.deepcopy(manifest)
    stale_hash["files"][0]["sha256"] = "0" * 64
    assert_raises(lambda: metadata.validate(stale_hash, ROOT))
    invalid_commit = copy.deepcopy(manifest)
    invalid_commit["fork"]["imported_commit"] = "master"
    assert_raises(lambda: metadata.validate(invalid_commit, ROOT))
    invalid_path = copy.deepcopy(manifest)
    invalid_path["files"][0]["path"] = "../LICENSE.md"
    assert_raises(lambda: metadata.validate(invalid_path, ROOT))

    entries = manifest["files"]
    assert_equal(len(entries), 3)
    files = {entry["path"]: entry["sha256"] for entry in entries}
    assert_equal(set(files), {"LICENSE.md", "src/md4c.c", "src/md4c.h"})
    for relative_path, expected_sha256 in files.items():
        actual_sha256 = hashlib.sha256((root / relative_path).read_bytes()).hexdigest()
        assert_equal(actual_sha256, expected_sha256)

    archive = subprocess.run(
        [
            "git",
            "archive",
            "--format=tar",
            "--prefix=ss-test/",
            "HEAD",
            "third_party/md4c",
            "third_party/md4c-manifest.json",
            "third_party/md4c-origin.md",
            "scripts/md4c.py",
        ],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
        timeout=30,
    ).stdout
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
        archived = set(source.getnames())
    required = {
        f"ss-test/third_party/md4c/{relative_path}"
        for relative_path in {
            "LICENSE.md",
            "README.md",
            "src/md4c.c",
            "src/md4c.h",
            "src/md4c-html.c",
            "CMakeLists.txt",
            "scripts/run-tests.py",
            "test/run-testsuite.py",
            "test/spec.txt",
            "test/spec-tables.txt",
        }
    }
    required.update({
        "ss-test/third_party/md4c-manifest.json",
        "ss-test/third_party/md4c-origin.md",
        "ss-test/scripts/md4c.py",
    })
    assert_equal(required - archived, set())

    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
            source.extractall(tmp, filter="data")
        subprocess.run(
            [sys.executable, str(pathlib.Path(tmp) / "ss-test/scripts/md4c.py"), "--check"],
            cwd=tmp,
            check=True,
            timeout=30,
        )


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
