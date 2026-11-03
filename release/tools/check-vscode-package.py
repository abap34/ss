#!/usr/bin/env python3
import argparse
import json
import pathlib
import xml.etree.ElementTree as xml
import zipfile


def check_package(package, extension_root, version):
    manifest = json.loads((extension_root / "package.json").read_text())
    outputs = extension_root / "out"
    if not (outputs / "extension.js").is_file():
        raise ValueError("build the extension before checking its package")
    required = [extension_root / manifest["main"]]
    required.extend(path for path in outputs.rglob("*") if path.is_file() and path.suffix != ".map")
    required.extend(path for path in (extension_root / "media/editor").rglob("*")
                    if path.is_file() and (path.suffix in {".js", ".css", ".LICENSE"} or path.name == "LICENSE"))
    required.extend(extension_root / item["configuration"] for item in manifest["contributes"]["languages"]
                    if "configuration" in item)
    required.extend(extension_root / item["path"] for item in manifest["contributes"]["grammars"])
    required.append(extension_root / manifest["icon"])

    with zipfile.ZipFile(package) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("VSIX contains duplicate file entries")
        if damaged := archive.testzip():
            raise ValueError(f"VSIX contains a damaged file: {damaged}")
        packaged = json.loads(archive.read("extension/package.json"))
        for key, expected in {"name": manifest["name"], "publisher": manifest["publisher"], "version": version, "main": manifest["main"]}.items():
            if packaged.get(key) != expected:
                raise ValueError(f"packaged {key}: expected {expected}, found {packaged.get(key)}")
        identity = xml.fromstring(archive.read("extension.vsixmanifest")).find(".//{*}Identity")
        if identity is None or identity.get("Version") != version or identity.get("Publisher") != manifest["publisher"]:
            raise ValueError("VSIX identity does not match the release version and publisher")
        for source in set(required):
            name = "extension/" + source.relative_to(extension_root).as_posix()
            if name not in names:
                raise ValueError(f"VSIX is missing runtime file: {name}")
            if archive.read(name) != source.read_bytes():
                raise ValueError(f"VSIX runtime file differs from the build: {name}")
    return len(set(required))


def main():
    parser = argparse.ArgumentParser(description="Check VSIX identity and all built and source runtime assets.")
    parser.add_argument("package", type=pathlib.Path)
    parser.add_argument("--extension-root", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[2] / "editor/vscode")
    parser.add_argument("--version")
    args = parser.parse_args()
    extension_root = args.extension_root.resolve()
    version = args.version or (extension_root.parents[1] / "release/VERSION").read_text().strip()
    try:
        count = check_package(args.package, extension_root, version)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, xml.ParseError) as error:
        parser.exit(1, f"VSIX validation failed: {error}\n")
    print(f"VSIX validated: {version}, {count} runtime files match the build")


if __name__ == "__main__":
    main()
