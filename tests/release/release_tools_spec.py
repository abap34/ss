#!/usr/bin/env python3
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "release" / "tools"))

from release_versions import (  # noqa: E402
    docker_metadata_tag_rules,
    homebrew_formula_class,
    homebrew_formula_name,
    parse_release_tag,
    parse_version,
    render_image_notes,
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


def test_patch_release_publish_metadata():
    assert_equal(
        docker_metadata_tag_rules("v0.7.1-patch.1"),
        [
            "type=ref,event=branch",
            "type=ref,event=tag",
            "type=sha,prefix=sha-",
        ],
    )
    assert_equal(
        render_image_notes("v0.7.1-patch.1", "ghcr.io/abap34/ss-render"),
        ["- ghcr.io/abap34/ss-render:v0.7.1-patch.1"],
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
        subprocess.run(["ruby", "-c", str(output)], check=True, timeout=30)


def main():
    test_release_version_parsing()
    test_homebrew_formula_names()
    test_patch_release_publish_metadata()
    test_render_homebrew_formula()


if __name__ == "__main__":
    main()
