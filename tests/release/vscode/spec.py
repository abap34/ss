#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "release/tools"))
spec = importlib.util.spec_from_file_location("publication", ROOT / "release/tools/prepare-vscode-publication.py")
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)
package_spec = importlib.util.spec_from_file_location("package_check", ROOT / "release/tools/check-vscode-package.py")
package_check = importlib.util.module_from_spec(package_spec)
package_spec.loader.exec_module(package_check)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ss-vscode-package-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.extension = self.root / "extension"
        self.package = self.root / "extension.vsix"
        manifest = {
            "name": "ss-language-support", "publisher": "abap34", "version": "0.8.4",
            "main": "./out/extension.js", "icon": "assets/logo.png",
            "contributes": {"languages": [{"configuration": "language-configuration.json"}],
                            "grammars": [{"path": "syntaxes/ss.json"}]},
        }
        self.files = {"extension/package.json": json.dumps(manifest).encode(),
                      "extension.vsixmanifest": b'<PackageManifest xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011"><Metadata><Identity Version="0.8.4" Publisher="abap34"/></Metadata></PackageManifest>'}
        for name in ("out/extension.js", "out/pdfjs/pdf.worker.mjs", "out/render/pdf.js",
                     "media/editor/main.js", "media/editor/main.css", "assets/logo.png",
                     "language-configuration.json", "syntaxes/ss.json"):
            self.files["extension/" + name] = name.encode()
        for name, content in self.files.items():
            if not name.startswith("extension/"):
                continue
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)

    def check(self, files=None, version="0.8.4"):
        with zipfile.ZipFile(self.package, "w") as archive:
            for name, content in (self.files if files is None else files).items():
                archive.writestr(name, content)
        return package_check.check_package(self.package, self.extension, version)

    def test_complete_runtime_matches_the_built_files(self):
        self.assertEqual(self.check(), 8)

    def test_missing_worker_and_source_modules_are_rejected(self):
        for missing in ("extension/out/pdfjs/pdf.worker.mjs", "extension/media/editor/main.js"):
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, "missing runtime file"):
                self.check({name: content for name, content in self.files.items() if name != missing})

    def test_stale_runtime_files_are_rejected(self):
        files = self.files | {"extension/out/render/pdf.js": b"stale runtime"}
        with self.assertRaisesRegex(ValueError, "differs from the build"):
            self.check(files)

    def test_release_and_vsix_manifest_versions_must_match(self):
        with self.assertRaisesRegex(ValueError, "packaged version"):
            self.check(version="0.9.0")
        files = self.files | {"extension.vsixmanifest": self.files["extension.vsixmanifest"].replace(b"0.8.4", b"0.8.3")}
        with self.assertRaisesRegex(ValueError, "VSIX identity"):
            self.check(files)


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
