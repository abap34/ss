#!/usr/bin/env python3
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
import urllib.request
import zipfile


MANIFEST = Path(__file__).resolve().parents[1] / "manifest.json"
MAX_ARCHIVE_BYTES = 40_000_000
MAX_BINARY_BYTES = 256 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verified(destination, expected):
    binary = destination / "trace_processor_shell"
    try:
        if destination.is_symlink() or binary.is_symlink():
            return False
        info = json.loads((destination / "verified.json").read_text(encoding="utf-8"))
        return (info.get("archive_sha256") == expected
                and binary.stat().st_size <= MAX_BINARY_BYTES
                and os.access(binary, os.X_OK)
                and info.get("binary_sha256") == digest(binary.read_bytes()))
    except (OSError, ValueError, AttributeError):
        return False


@contextmanager
def installation_lock(path, timeout):
    # Keep the inode: unlinking it could let a third process lock another inode
    # while an existing waiter still holds this one. The OS releases flock even
    # when an installer is killed, so no stale-owner recovery is needed.
    with path.open("ab") as lock:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"timed out waiting for Trace Processor installation: {path}")
                time.sleep(0.05)
        yield


def install_processor(cache, platform, *, manifest_path=MANIFEST, opener=urllib.request.urlopen, lock_timeout=90):
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or platform not in manifest.get("trace_processor", {}):
        raise ValueError(f"no pinned Trace Processor for {platform}")
    version = "v" + manifest["version"]
    archive_name, expected = manifest["trace_processor"][platform]
    parent = cache / version
    destination = parent / platform
    binary = destination / "trace_processor_shell"
    if verified(destination, expected):
        return binary
    parent.mkdir(parents=True, exist_ok=True)
    with installation_lock(parent / f".{platform}.lock", lock_timeout):
        if verified(destination, expected):
            return binary
        request = urllib.request.Request(
            f"https://github.com/google/perfetto/releases/download/{version}/{archive_name}",
            headers={"User-Agent": "ss-perfetto-fetch"},
        )
        with opener(request, timeout=60) as response:
            data = response.read(MAX_ARCHIVE_BYTES + 1)
        if len(data) > MAX_ARCHIVE_BYTES or digest(data) != expected:
            raise ValueError("Trace Processor archive checksum mismatch or size limit exceeded")
        with tempfile.TemporaryDirectory(prefix="download-", dir=parent) as temporary:
            staged = Path(temporary) / "processor"
            staged.mkdir()
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                entries = [entry for entry in archive.infolist()
                           if entry.filename.rsplit("/", 1)[-1] == "trace_processor_shell" and not entry.is_dir()]
                if len(entries) != 1 or entries[0].file_size > MAX_BINARY_BYTES:
                    raise ValueError("expected exactly one bounded Trace Processor binary")
                contents = archive.read(entries[0])
            staged_binary = staged / binary.name
            staged_binary.write_bytes(contents)
            staged_binary.chmod(0o755)
            (staged / "verified.json").write_text(json.dumps({
                "version": version, "archive_sha256": expected, "binary_sha256": digest(contents),
            }), encoding="utf-8")
            # A valid destination is reused above, never removed by another
            # installer. Only an invalid cache is replaced, after staging passes.
            if destination.is_symlink() or destination.is_file():
                destination.unlink()
            elif destination.exists():
                shutil.rmtree(destination)
            staged.rename(destination)
        return binary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--platform", required=True)
    args = parser.parse_args()
    try:
        binary = install_processor(args.cache.resolve(), args.platform)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Trace Processor: {error}\n")
    print(binary)


if __name__ == "__main__":
    main()
