#!/usr/bin/env python3
import argparse
import hashlib
import io
import json
from pathlib import Path
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
MAX_ARCHIVE_BYTES = 16 * 1024 * 1024
MAX_SOURCE_BYTES = 16 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_manifest(path):
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1:
        raise ValueError("unsupported Perfetto manifest schema")
    if set(manifest.get("files", {})) != {"perfetto.cc", "perfetto.h"}:
        raise ValueError("Perfetto manifest must name exactly perfetto.cc and perfetto.h")
    for value in [manifest["sha256"], *manifest["files"].values()]:
        if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
            raise ValueError("invalid SHA-256 in Perfetto manifest")
    if not manifest["url"].startswith("https://"):
        raise ValueError("Perfetto archive URL must use HTTPS")
    return manifest


def verify_sdk(destination, manifest):
    if destination.is_symlink() or not destination.is_dir():
        return False
    for name, expected in manifest["files"].items():
        source = destination / name
        if source.is_symlink() or not source.is_file() or source.stat().st_size > MAX_SOURCE_BYTES:
            return False
        if digest(source.read_bytes()) != expected:
            return False
    return True


def fetch_sdk(manifest_path, destination, *, check=False, opener=urllib.request.urlopen):
    manifest = load_manifest(manifest_path)
    if verify_sdk(destination, manifest):
        return False
    if check:
        raise ValueError("Perfetto SDK is missing or does not match the pinned sources")
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"SDK contents differ from the manifest; move {destination} aside before fetching again")
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock = destination.parent / ".fetch.lock"
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise RuntimeError(f"another SDK fetch may be running; inspect {lock}") from error
    try:
        # Another fetch may have finished between the initial check and locking.
        if verify_sdk(destination, manifest):
            return False
        if destination.exists() or destination.is_symlink():
            raise ValueError(f"SDK destination already exists: {destination}")
        request = urllib.request.Request(manifest["url"], headers={"User-Agent": "ss-perfetto-fetch"})
        with opener(request, timeout=30) as response:
            archive_bytes = response.read(MAX_ARCHIVE_BYTES + 1)
        if len(archive_bytes) > MAX_ARCHIVE_BYTES:
            raise ValueError("Perfetto archive exceeds the size limit")
        if digest(archive_bytes) != manifest["sha256"]:
            raise ValueError("Perfetto archive SHA-256 mismatch")
        with tempfile.TemporaryDirectory(prefix=".fetch-", dir=destination.parent) as temporary:
            staged = Path(temporary) / "sdk"
            staged.mkdir()
            with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
                names = archive.namelist()
                if len(names) != len(set(names)) or set(names) != set(manifest["files"]):
                    raise ValueError("Perfetto archive has unexpected or duplicate entries")
                for name, expected in manifest["files"].items():
                    entry = archive.getinfo(name)
                    if entry.file_size > MAX_SOURCE_BYTES:
                        raise ValueError(f"Perfetto source exceeds the size limit: {name}")
                    data = archive.read(entry)
                    if digest(data) != expected:
                        raise ValueError(f"Perfetto source SHA-256 mismatch: {name}")
                    (staged / name).write_bytes(data)
            staged.rename(destination)
        return True
    finally:
        lock.rmdir()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify existing sources without downloading")
    args = parser.parse_args()
    try:
        changed = fetch_sdk(ROOT / "manifest.json", ROOT / "sdk", check=args.check)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Perfetto SDK: {error}\n")
    print("Perfetto SDK downloaded and verified." if changed else "Perfetto SDK matches the pinned sources.")


if __name__ == "__main__":
    main()
