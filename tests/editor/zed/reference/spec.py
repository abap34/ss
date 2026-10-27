import importlib.util
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[4]
spec = importlib.util.spec_from_file_location("zed_grammar", ROOT / "editor/zed/tools/check-grammar.py")
grammar = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = grammar
spec.loader.exec_module(grammar)


class GrammarReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ss-zed-reference-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "source"
        self.source.mkdir()
        grammar.run_git("init", "--quiet", self.source)
        grammar.run_git("-C", self.source, "config", "user.name", "Test Author")
        grammar.run_git("-C", self.source, "config", "user.email", "test@example.invalid")
        for name in grammar.GRAMMAR_FILES:
            file = self.source / "editor/tree-sitter-ss" / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(f"Fixture: {name}\n")
        self.commit()

    def commit(self):
        grammar.run_git("-C", self.source, "add", ".")
        grammar.run_git("-C", self.source, "commit", "--quiet", "-m", "Update fixture grammar")
        return grammar.run_git("-C", self.source, "rev-parse", "HEAD")

    def publish(self):
        origin = self.directory / "origin.git"
        grammar.run_git("clone", "--bare", "--quiet", self.source, origin)
        revision = grammar.run_git("-C", self.source, "rev-parse", "HEAD")
        return grammar.GrammarReference(origin.as_uri(), revision, "editor/tree-sitter-ss")

    def manifest(self, repository="https://github.com/example/grammar", revision=None, path="editor/tree-sitter-ss"):
        file = self.directory / "extension.toml"
        revision = revision or grammar.run_git("-C", self.source, "rev-parse", "HEAD")
        file.write_text(f"[grammars.ss]\nrepository = '{repository}'\nrev = '{revision}'\npath = '{path}'\n")
        return file

    def test_reads_toml_reference(self):
        reference = grammar.read_reference(self.manifest())
        self.assertEqual(reference.repository, "https://github.com/example/grammar")
        self.assertEqual(reference.path, "editor/tree-sitter-ss")

    def test_rejects_invalid_reference_fields(self):
        cases = [
            ({"revision": "main"}, "full commit SHA"),
            ({"repository": "http://github.com/example/grammar"}, "HTTPS GitHub"),
            ({"path": "../tree-sitter-ss"}, "relative grammar directory"),
            ({"path": "/tree-sitter-ss"}, "relative grammar directory"),
        ]
        for fields, message in cases:
            with self.subTest(fields=fields), self.assertRaisesRegex(ValueError, message):
                grammar.read_reference(self.manifest(**fields))

    def test_fetches_published_grammar_into_an_empty_repository(self):
        reference = self.publish()
        repository = grammar.fetch_reference(reference, self.directory / "verified.git")
        content = grammar.run_git("--git-dir", repository, "show", f"FETCH_HEAD:{reference.path}/grammar.js")
        self.assertEqual(content, "Fixture: grammar.js")
        self.assertFalse((repository / "objects/info/alternates").exists())

    def test_rejects_local_only_commit_even_when_checkout_contains_it(self):
        published = self.publish()
        (self.source / "editor/tree-sitter-ss/grammar.js").write_text("Unpublished grammar\n")
        revision = self.commit()
        grammar.run_git("-C", self.source, "cat-file", "-e", f"{revision}^{{commit}}")
        reference = grammar.GrammarReference(published.repository, revision, published.path)
        inherited = {
            "GIT_DIR": str(self.source / ".git"),
            "GIT_OBJECT_DIRECTORY": str(self.source / ".git/objects"),
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(self.source / ".git/objects"),
        }
        with patch.dict(os.environ, inherited), self.assertRaisesRegex(RuntimeError, f"cannot fetch grammar revision {revision}"):
            grammar.fetch_reference(reference, self.directory / "verified.git")

    def test_rejects_published_commit_without_required_grammar_files(self):
        (self.source / "editor/tree-sitter-ss/src/parser.c").unlink()
        self.commit()
        reference = self.publish()
        with self.assertRaisesRegex(ValueError, "does not contain editor/tree-sitter-ss/src/parser.c"):
            grammar.fetch_reference(reference, self.directory / "verified.git")

    def test_archive_contains_the_verified_sources_only(self):
        reference = self.publish()
        manifest = self.manifest()
        archive = self.directory / "grammar.tar"
        with patch.object(grammar, "read_reference", return_value=reference):
            self.assertEqual(grammar.check_reference(manifest, archive), reference)
        with tarfile.open(archive) as contents:
            names = {entry.name for entry in contents if entry.isfile()}
            self.assertEqual(names, {f"{reference.path}/{name}" for name in grammar.GRAMMAR_FILES})
            self.assertEqual(contents.extractfile(f"{reference.path}/grammar.js").read(), b"Fixture: grammar.js\n")


if __name__ == "__main__":
    unittest.main()
