import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("perfetto_fetch", ROOT / "third_party/perfetto/tools/fetch.py")
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.destination = self.root / "sdk"
        self.sources = {"perfetto.cc": b"test source\n", "perfetto.h": b"test header\n"}
        self.archive = self.pack(self.sources)
        self.manifest = {
            "schema": 1,
            "version": "test",
            "url": "https://example.invalid/sdk.zip",
            "sha256": fetcher.digest(self.archive),
            "files": {name: fetcher.digest(data) for name, data in self.sources.items()},
        }
        self.path = self.root / "manifest.json"
        self.save_manifest()

    @staticmethod
    def pack(sources):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            for name, data in sources.items():
                archive.writestr(name, data)
        return output.getvalue()

    def save_manifest(self):
        self.path.write_text(json.dumps(self.manifest), encoding="utf-8")

    def fetch(self, **options):
        return fetcher.fetch_sdk(self.path, self.destination, opener=lambda *a, **k: io.BytesIO(self.archive), **options)

    def test_verified_sources_are_published_and_reused_without_network(self):
        self.assertTrue(self.fetch())
        self.assertEqual((self.destination / "perfetto.cc").read_bytes(), self.sources["perfetto.cc"])
        def unexpected_network(*args, **kwargs):
            self.fail("unexpected network")
        self.assertFalse(fetcher.fetch_sdk(self.path, self.destination, opener=unexpected_network))
        self.assertFalse(fetcher.fetch_sdk(self.path, self.destination, check=True, opener=unexpected_network))
        self.assertFalse((self.root / ".fetch.lock").exists())

    def test_missing_check_never_downloads_or_creates_directories(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            self.fetch(check=True)
        self.assertFalse(self.destination.exists())
        self.assertFalse((self.root / ".fetch.lock").exists())

    def test_archive_digest_mismatch_does_not_publish_partial_sdk(self):
        self.archive += b"unexpected bytes"
        with self.assertRaisesRegex(ValueError, "archive SHA-256"):
            self.fetch()
        self.assertFalse(self.destination.exists())
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["manifest.json"])

    def test_source_digest_mismatch_does_not_publish_partial_sdk(self):
        self.manifest["files"]["perfetto.h"] = "0" * 64
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "source SHA-256"):
            self.fetch()
        self.assertFalse(self.destination.exists())

    def test_unexpected_archive_paths_are_rejected(self):
        self.archive = self.pack({**self.sources, "../outside": b"unsafe"})
        self.manifest["sha256"] = fetcher.digest(self.archive)
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "unexpected"):
            self.fetch()
        self.assertFalse(self.destination.exists())

    def test_existing_modified_sources_are_preserved(self):
        self.fetch()
        source = self.destination / "perfetto.cc"
        source.write_bytes(b"local edit")
        with self.assertRaisesRegex(ValueError, "move .* aside"):
            self.fetch()
        self.assertEqual(source.read_bytes(), b"local edit")

    def test_fetch_failure_releases_lock(self):
        def interrupted(*args, **kwargs):
            raise OSError("interrupted")
        with self.assertRaisesRegex(OSError, "interrupted"):
            fetcher.fetch_sdk(self.path, self.destination, opener=interrupted)
        self.assertFalse((self.root / ".fetch.lock").exists())
        self.assertTrue(self.fetch())

    def test_concurrent_fetch_is_rejected(self):
        lock = self.root / ".fetch.lock"
        lock.mkdir()
        with self.assertRaisesRegex(RuntimeError, "another SDK fetch"):
            self.fetch()
        self.assertTrue(lock.exists())


if __name__ == "__main__":
    unittest.main()
