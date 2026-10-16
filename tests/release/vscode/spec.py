#!/usr/bin/env python3
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "release/tools"))
spec = importlib.util.spec_from_file_location("publication", ROOT / "release/tools/prepare-vscode-publication.py")
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.com")
        for name in (*publication.VALIDATION_FILES, "source.zig", "release/VERSION"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("original release\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Release sources")
        self.release_commit = self.git("rev-parse", "HEAD")
        self.git("tag", "v0.8.4")
        for name in (*publication.VALIDATION_FILES, "source.zig"):
            (self.root / name).write_text("current main\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Later implementation and validation")
        self.control_commit = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return publication.git(self.root, *args)

    def test_release_sources_and_version_remain_exactly_at_the_tag(self):
        self.assertEqual(publication.prepare(self.root, "v0.8.4"), self.release_commit)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.release_commit)
        self.assertEqual((self.root / "source.zig").read_text(), "original release\n")
        self.assertEqual((self.root / "release/VERSION").read_text(), "original release\n")
        for name in publication.VALIDATION_FILES:
            self.assertEqual((self.root / name).read_text(), "current main\n")
        self.assertEqual(set(self.git("diff", "--name-only").splitlines()), set(publication.VALIDATION_FILES))
        self.git("restore", "--", *publication.VALIDATION_FILES)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_invalid_or_missing_tags_leave_checkout_unchanged(self):
        for tag in ("main", "refs/tags/v0.8.4", "v0.8.4-patch.1", "v9.9.9"):
            with self.subTest(tag=tag), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                publication.prepare(self.root, tag)
            self.assertEqual(self.git("rev-parse", "HEAD"), self.control_commit)
            self.assertEqual(self.git("status", "--porcelain"), "")

    def test_uncommitted_tracked_changes_are_preserved(self):
        (self.root / "source.zig").write_text("uncommitted\n")
        with self.assertRaisesRegex(ValueError, "tracked files must be clean"):
            publication.prepare(self.root, "v0.8.4")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.control_commit)
        self.assertEqual((self.root / "source.zig").read_text(), "uncommitted\n")


if __name__ == "__main__":
    unittest.main()
