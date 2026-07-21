#!/usr/bin/env python3
import argparse
import dataclasses
import re
import sys


VERSION_RE = re.compile(
    r"^(?P<major>0|[1-9][0-9]*)\."
    r"(?P<minor>0|[1-9][0-9]*)\."
    r"(?P<patch>0|[1-9][0-9]*)"
    r"(?:-(?P<prerelease>patch\.(?P<patch_release>[1-9][0-9]*)))?$"
)


@dataclasses.dataclass(frozen=True)
class ReleaseVersion:
    version: str
    major: int
    minor: int
    patch: int
    prerelease: str | None = None
    patch_release: int | None = None

    @property
    def tag(self) -> str:
        return f"v{self.version}"

    @property
    def is_patch_release(self) -> bool:
        return self.patch_release is not None


def supported_version_hint() -> str:
    return "v0.1.0 or v0.1.1-patch.1"


def normalize_tag(value: str) -> str:
    if value.startswith("refs/tags/"):
        value = value.removeprefix("refs/tags/")
    return value


def parse_version(value: str) -> ReleaseVersion:
    match = VERSION_RE.fullmatch(value)
    if not match:
        raise ValueError(f"release version must look like 0.1.0 or 0.1.1-patch.1, got {value}")
    patch_release = match.group("patch_release")
    return ReleaseVersion(
        version=value,
        major=int(match.group("major")),
        minor=int(match.group("minor")),
        patch=int(match.group("patch")),
        prerelease=match.group("prerelease"),
        patch_release=int(patch_release) if patch_release is not None else None,
    )


def parse_release_tag(value: str) -> ReleaseVersion:
    normalized = normalize_tag(value)
    if not normalized.startswith("v"):
        raise ValueError(f"release tag must look like {supported_version_hint()}, got {value}")
    return parse_version(normalized.removeprefix("v"))


def require_release_tag(value: str) -> str:
    return parse_release_tag(value).tag


def release_version(value: str) -> str:
    return parse_release_tag(value).version


def homebrew_formula_name(version: str) -> str:
    parsed = parse_version(version)
    if parsed.is_patch_release:
        return f"ss@{parsed.version}"
    return "ss"


def homebrew_formula_class(formula_name: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9@._+-]*", formula_name):
        raise ValueError(f"invalid Homebrew formula name: {formula_name}")

    normalized = formula_name.replace("@", "-AT-")
    parts = [part for part in re.split(r"[^A-Za-z0-9]+", normalized) if part]
    class_parts: list[str] = []
    for part in parts:
        if part == "AT":
            class_parts.append("AT")
        elif part[0].isdigit():
            class_parts.append(part)
        else:
            class_parts.append(part[0].upper() + part[1:])
    return "".join(class_parts)


def version_argument(value: str) -> str:
    if value.startswith("v") or value.startswith("refs/tags/"):
        return parse_release_tag(value).version
    return parse_version(value).version


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve ss release version metadata.")
    subcommands = parser.add_subparsers(dest="command", required=True)

    validate = subcommands.add_parser("validate-tag", help="Validate a release tag.")
    validate.add_argument("tag")

    version = subcommands.add_parser("version", help="Print the SemVer version for a release tag or version.")
    version.add_argument("value")

    formula = subcommands.add_parser("homebrew-formula-name", help="Print the Homebrew formula name for a release version.")
    formula.add_argument("value")

    args = parser.parse_args()
    try:
        if args.command == "validate-tag":
            parse_release_tag(args.tag)
        elif args.command == "version":
            print(version_argument(args.value))
        elif args.command == "homebrew-formula-name":
            print(homebrew_formula_name(version_argument(args.value)))
        else:
            parser.error(f"unknown command: {args.command}")
    except ValueError as err:
        print(err, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
