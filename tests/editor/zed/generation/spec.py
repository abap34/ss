import json
import os
from pathlib import Path
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "editor/zed/tools"))
import grammar
import prepare


class ExtensionGenerationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ss-zed-generation-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.source = self.directory / "source"
        self.source.mkdir()
        self.output = self.directory / "generated extension"
        self.origin = self.directory / "origin.git"
        self.template = f'''id = "ss"
version = "0.1.0"
repository = "{self.origin.as_uri()}"
[language_servers.ss]
language = "ss"
'''
        self.write("editor/zed/extension.toml.in", self.template)
        self.write("editor/zed/Cargo.toml", "[package]\nname = 'fixture'\n")
        self.write("editor/zed/Cargo.lock", "version = 4\n")
        self.write("editor/zed/src/lib.rs", "// Original extension\n")
        self.write("editor/zed/languages/ss/highlights.scm", "; Original queries\n")
        for name in grammar.GRAMMAR_FILES:
            self.write(f"{grammar.GRAMMAR_PATH}/{name}", f"Fixture: {name}\n")
        self.write(f"{grammar.GRAMMAR_PATH}/src/scanner.c", "// External scanner\n")
        self.write(f"{grammar.GRAMMAR_PATH}/src/tree_sitter/parser.h", "// Parser header\n")
        grammar.run_git("init", "--quiet", self.source)
        grammar.run_git("-C", self.source, "config", "user.name", "Test Author")
        grammar.run_git("-C", self.source, "config", "user.email", "test@example.invalid")
        self.revision = self.commit()
        grammar.run_git("clone", "--bare", "--quiet", self.source, self.origin)

    def write(self, name, content):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self):
        grammar.run_git("-C", self.source, "add", ".")
        grammar.run_git("-C", self.source, "commit", "--quiet", "-m", "Update fixture")
        return grammar.run_git("-C", self.source, "rev-parse", "HEAD")

    def generate(self, mode="dev", revision=None):
        return prepare.prepare(mode, self.output, revision=revision, root=self.source)

    def manifest(self):
        return self.output / "extension/extension.toml"

    def test_development_uses_uncommitted_sources_without_changing_the_source_repository(self):
        self.write(f"{grammar.GRAMMAR_PATH}/src/parser.c", "// Uncommitted parser\n")
        self.write(f"{grammar.GRAMMAR_PATH}/src/new.h", "// Untracked header\n")
        before = grammar.run_git("-C", self.source, "status", "--porcelain")
        report = self.generate()
        self.assertTrue(report["repository"].startswith("file:///"))
        reference = grammar.check_reference(self.manifest(), allow_local=True)
        fetched = grammar.fetch_reference(reference, self.directory / "independent.git")
        for name, content in [("parser.c", "// Uncommitted parser"), ("new.h", "// Untracked header")]:
            actual = grammar.run_git("--git-dir", fetched, "show", f"{reference.revision}:{grammar.GRAMMAR_PATH}/src/{name}")
            self.assertEqual(actual, content)
        self.assertEqual(grammar.run_git("-C", self.source, "status", "--porcelain"), before)
        self.assertEqual(grammar.run_git("-C", self.source, "rev-parse", "HEAD"), self.revision)

    def test_same_grammar_keeps_its_revision_after_source_history_changes(self):
        first = self.generate()
        self.write("unrelated.txt", "Different source commit\n")
        self.commit()
        second = self.generate()
        self.assertEqual(first, second)

    def test_generation_replaces_changed_and_deleted_sources_and_excludes_caches(self):
        first = self.generate()
        self.write(f"{grammar.GRAMMAR_PATH}/src/parser.c", "// Changed parser\n")
        (self.source / "editor/zed/languages/ss/highlights.scm").unlink()
        self.write("editor/zed/languages/ss/outline.scm", "; New query\n")
        self.write("editor/zed/target/cache", "Cache\n")
        self.write("editor/zed/extension.wasm", "Binary\n")
        second = self.generate()
        self.assertNotEqual(first["revision"], second["revision"])
        extension = Path(second["extension"])
        self.assertFalse((extension / "languages/ss/highlights.scm").exists())
        self.assertTrue((extension / "languages/ss/outline.scm").is_file())
        self.assertFalse((extension / "target").exists())
        self.assertFalse((extension / "extension.wasm").exists())
        self.assertFalse((extension / prepare.TEMPLATE).exists())

    def test_release_takes_extension_and_grammar_from_the_same_published_commit(self):
        self.write("editor/zed/src/lib.rs", "// Local changes\n")
        self.write("editor/zed/languages/ss/highlights.scm", "; Local queries\n")
        self.write(f"{grammar.GRAMMAR_PATH}/src/parser.c", "// Local parser\n")
        report = self.generate("release", self.revision)
        self.assertEqual(report["repository"], self.origin.as_uri())
        self.assertEqual(report["revision"], self.revision)
        self.assertEqual((self.output / "extension/src/lib.rs").read_text(), "// Original extension\n")
        self.assertEqual((self.output / "extension/languages/ss/highlights.scm").read_text(), "; Original queries\n")
        self.assertFalse((self.output / "grammar").exists())
        grammar.check_reference(self.manifest(), allow_local=True)

    def test_release_can_prepare_an_older_manifest_without_the_template(self):
        (self.source / "editor/zed/extension.toml.in").unlink()
        old = self.template + f'\n[grammars.ss]\nrepository = "https://github.com/example/old"\nrev = "{"a" * 40}"\npath = "old"\n'
        self.write("editor/zed/extension.toml", old)
        revision = self.commit()
        grammar.run_git("-C", self.source, "push", "--quiet", self.origin, "HEAD:refs/heads/published")
        self.write("editor/zed/extension.toml.in", self.template)
        self.generate("release", revision)
        manifest = tomllib.loads(self.manifest().read_text())
        self.assertEqual(manifest["grammars"]["ss"]["rev"], revision)
        self.assertEqual(manifest["grammars"]["ss"]["repository"], self.origin.as_uri())
        self.assertEqual(manifest["language_servers"]["ss"]["language"], "ss")

    def test_unpublished_revision_cannot_borrow_the_source_repository_objects(self):
        self.generate()
        before = self.manifest().read_bytes()
        self.write(f"{grammar.GRAMMAR_PATH}/src/parser.c", "// Unpublished parser\n")
        revision = self.commit()
        inherited = {"GIT_DIR": str(self.source / ".git"), "GIT_OBJECT_DIRECTORY": str(self.source / ".git/objects")}
        with patch.dict(os.environ, inherited), self.assertRaisesRegex(RuntimeError, "cannot fetch grammar revision"):
            self.generate("release", revision)
        self.assertEqual(self.manifest().read_bytes(), before)

    def test_failed_generation_keeps_the_previous_extension(self):
        self.generate()
        before = self.manifest().read_bytes()
        (self.source / f"{grammar.GRAMMAR_PATH}/src/parser.c").unlink()
        with self.assertRaisesRegex(ValueError, "missing grammar source"):
            self.generate()
        self.assertEqual(self.manifest().read_bytes(), before)

    def test_output_must_not_replace_unrelated_directories_or_sources(self):
        self.output.mkdir()
        marker = self.output / "keep.txt"
        marker.write_text("User data\n")
        with self.assertRaisesRegex(ValueError, "unrelated output directory"):
            self.generate()
        self.assertEqual(marker.read_text(), "User data\n")
        for output in [self.source, self.source / "editor/zed/src/generated", self.source / grammar.GRAMMAR_PATH]:
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "separate from"):
                prepare.prepare("dev", output, root=self.source)

    def test_output_symlinks_are_not_followed(self):
        self.output.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "must not be a symlink"):
            self.generate()

    def test_source_symlinks_are_not_copied(self):
        (self.source / "editor/zed/src/secret.rs").symlink_to(self.source / "editor/zed/Cargo.lock")
        with self.assertRaisesRegex(ValueError, "must not be symlinks"):
            self.generate()
        self.assertFalse(self.output.exists())

    def test_revision_must_be_immutable_and_is_only_used_for_releases(self):
        for revision in [None, "main", "v0.1.0", "--upload-pack=invalid"]:
            with self.subTest(revision=revision), self.assertRaisesRegex(ValueError, "full commit SHA"):
                self.generate("release", revision)
        with self.assertRaisesRegex(ValueError, "only used for release"):
            self.generate("dev", self.revision)


if __name__ == "__main__":
    unittest.main()
