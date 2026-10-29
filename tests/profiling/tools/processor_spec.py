import importlib.util
import io
import json
import multiprocessing
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("processor", ROOT / "third_party/perfetto/tools/processor.py")
processor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(processor)


def install_worker(manifest, cache, data, barrier, downloads, started, release, results):
    def opener(*args, **kwargs):
        with downloads.get_lock():
            downloads.value += 1
        started.set()
        if not release.wait(10):
            raise TimeoutError("download barrier timed out")
        return io.BytesIO(data)

    try:
        barrier.wait(timeout=10)
        binary = processor.install_processor(Path(cache), "linux-x64", manifest_path=Path(manifest), opener=opener)
        results.put(("ok", str(binary)))
    except Exception as error:
        results.put(("error", repr(error)))


class ProcessorTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ss-processor-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cache = self.root / "tools"
        self.manifest_path = self.root / "manifest.json"
        self.binary = b"#!/bin/sh\nprintf 'test processor\\n'\n"
        self.archive = self.pack({"tools/trace_processor_shell": self.binary})
        self.manifest = {"schema": 1, "version": "test", "trace_processor": {
            "linux-x64": ["linux-amd64.zip", processor.digest(self.archive)],
        }}
        self.save_manifest()
        self.context = multiprocessing.get_context("spawn")

    @staticmethod
    def pack(files):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        return output.getvalue()

    def save_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")

    def install(self, **options):
        return processor.install_processor(self.cache, "linux-x64", manifest_path=self.manifest_path,
                                           opener=lambda *args, **kwargs: io.BytesIO(self.archive), **options)

    def launch(self, barrier, downloads, started, release, results):
        child = self.context.Process(target=install_worker, args=(
            str(self.manifest_path), str(self.cache), self.archive, barrier, downloads, started, release, results,
        ))
        child.start()
        self.addCleanup(self.stop, child)
        return child

    @staticmethod
    def stop(child):
        if child.is_alive():
            child.kill()
        child.join(timeout=5)

    def events(self, count):
        results = self.context.Queue()
        self.addCleanup(results.close)
        return (self.context.Barrier(count), self.context.Value("i", 0),
                self.context.Event(), self.context.Event(), results)

    def test_verified_binary_is_reused_without_network_or_replacement(self):
        binary = self.install()
        inode = binary.stat().st_ino
        def unexpected_download(*args, **kwargs):
            self.fail("unexpected download")
        reused = processor.install_processor(self.cache, "linux-x64", manifest_path=self.manifest_path,
                                              opener=unexpected_download)
        self.assertEqual(binary, reused)
        self.assertEqual(binary.stat().st_ino, inode)
        result = subprocess.run([str(binary)], capture_output=True, timeout=5, check=True)
        self.assertEqual(result.stdout, b"test processor\n")

    def test_concurrent_cold_install_downloads_once_and_preserves_published_binary(self):
        barrier, downloads, started, release, results = self.events(4)
        children = [self.launch(barrier, downloads, started, release, results) for _ in range(4)]
        self.assertTrue(started.wait(10), "installer did not reach the download")
        release.set()
        replies = [results.get(timeout=15) for _ in children]
        for child in children:
            child.join(timeout=5)
            self.assertEqual(child.exitcode, 0)
        self.assertTrue(all(status == "ok" for status, _ in replies), replies)
        self.assertEqual(len({name for _, name in replies}), 1)
        self.assertEqual(downloads.value, 1)
        binary = Path(replies[0][1])
        self.assertEqual(binary.read_bytes(), self.binary)
        inode = binary.stat().st_ino
        self.assertEqual(self.install().stat().st_ino, inode)
        self.assertEqual(list(binary.parent.parent.glob("download-*")), [])

    def test_killed_owner_releases_lock_without_stale_lock_recovery(self):
        barrier, downloads, started, release, results = self.events(1)
        owner = self.launch(barrier, downloads, started, release, results)
        self.assertTrue(started.wait(10), "installer did not acquire the lock")
        owner.kill()
        owner.join(timeout=5)
        self.assertIsNotNone(owner.exitcode)
        self.assertEqual(self.install(lock_timeout=1).read_bytes(), self.binary)

    def test_lock_wait_has_a_deadline_and_does_not_break_an_active_lock(self):
        barrier, downloads, started, release, results = self.events(1)
        owner = self.launch(barrier, downloads, started, release, results)
        self.assertTrue(started.wait(10), "installer did not acquire the lock")
        with self.assertRaisesRegex(TimeoutError, "waiting for Trace Processor"):
            self.install(lock_timeout=0.05)
        self.assertEqual(downloads.value, 1)
        release.set()
        self.assertEqual(results.get(timeout=15)[0], "ok")
        owner.join(timeout=5)
        self.assertEqual(owner.exitcode, 0)

    def test_failed_download_and_checksum_failure_allow_retry(self):
        def failed_download(*args, **kwargs):
            raise OSError("interrupted download")
        with self.assertRaisesRegex(OSError, "interrupted download"):
            processor.install_processor(self.cache, "linux-x64", manifest_path=self.manifest_path,
                                        opener=failed_download)
        original = self.archive
        self.archive = b"damaged"
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.install()
        self.archive = original
        self.assertEqual(self.install(lock_timeout=1).read_bytes(), self.binary)

    def test_invalid_cache_is_replaced_only_after_verified_download(self):
        binary = self.install()
        binary.write_bytes(b"modified")
        original = self.archive
        self.archive = b"damaged"
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(binary.read_bytes(), b"modified")
        self.archive = original
        self.assertEqual(self.install().read_bytes(), self.binary)
        self.assertEqual(list(binary.parent.parent.glob("download-*")), [])

    def test_ambiguous_or_oversized_archives_are_rejected_without_publication(self):
        for files in ({"a/trace_processor_shell": self.binary, "b/trace_processor_shell": self.binary},
                      {"unrelated": self.binary}):
            self.archive = self.pack(files)
            self.manifest["trace_processor"]["linux-x64"][1] = processor.digest(self.archive)
            self.save_manifest()
            with self.assertRaisesRegex(ValueError, "exactly one"):
                self.install()
        self.archive = self.pack({"trace_processor_shell": self.binary})
        self.manifest["trace_processor"]["linux-x64"][1] = processor.digest(self.archive)
        self.save_manifest()
        with patch.object(processor, "MAX_BINARY_BYTES", len(self.binary) - 1):
            with self.assertRaisesRegex(ValueError, "bounded"):
                self.install()
        with patch.object(processor, "MAX_ARCHIVE_BYTES", len(self.archive) - 1):
            with self.assertRaisesRegex(ValueError, "size limit"):
                self.install()
        self.assertFalse((self.cache / "vtest/linux-x64").exists())
        self.assertEqual(list((self.cache / "vtest").glob("download-*")), [])


if __name__ == "__main__":
    unittest.main()
