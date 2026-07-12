#!/usr/bin/env python3
import argparse
import dataclasses
import pathlib
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


def is_patch_release_tag(value: str) -> bool:
    try:
        return parse_release_tag(value).is_patch_release
    except ValueError:
        return False


def docker_metadata_tag_rules(ref_name: str) -> list[str]:
    rules = [
        "type=ref,event=branch",
        "type=ref,event=tag",
    ]
    if not is_patch_release_tag(ref_name):
        rules.extend(
            [
                "type=semver,pattern=v{{version}}",
                "type=semver,pattern=v{{major}}.{{minor}}",
                "type=semver,pattern=v{{major}}",
                "type=semver,pattern={{version}}",
                "type=semver,pattern={{major}}.{{minor}}",
                "type=semver,pattern={{major}}",
            ]
        )
    rules.append("type=sha,prefix=sha-")
    return rules


def render_image_notes(tag: str, image: str) -> list[str]:
    if is_patch_release_tag(tag):
        return [f"- {image}:{tag}"]
    return [
        f"- {image}:{tag}",
        f"- {image}:{tag.rsplit('.', 1)[0]}",
        f"- {image}:{tag.split('.', 1)[0]}",
    ]


def version_or_dev(ref_name: str, root: pathlib.Path) -> str:
    try:
        return parse_release_tag(ref_name).version
    except ValueError:
        return (root / "release" / "VERSION").read_text(encoding="utf-8").strip() + "-dev"


def version_argument(value: str) -> str:
    if value.startswith("v") or value.startswith("refs/tags/"):
        return parse_release_tag(value).version
    return parse_version(value).version


def print_github_multiline(name: str, lines: list[str]) -> None:
    print(f"{name}<<EOF")
    for line in lines:
        print(line)
    print("EOF")


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve ss release version metadata.")
    subcommands = parser.add_subparsers(dest="command", required=True)

    validate = subcommands.add_parser("validate-tag", help="Validate a release tag.")
    validate.add_argument("tag")

    version = subcommands.add_parser("version", help="Print the SemVer version for a release tag or version.")
    version.add_argument("value")

    version_dev = subcommands.add_parser("version-or-dev", help="Print release version for a tag, or <release/VERSION>-dev otherwise.")
    version_dev.add_argument("ref_name")
    version_dev.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())

    formula = subcommands.add_parser("homebrew-formula-name", help="Print the Homebrew formula name for a release version.")
    formula.add_argument("value")

    docker_rules = subcommands.add_parser("docker-tag-rules", help="Print docker/metadata-action tag rules for a ref.")
    docker_rules.add_argument("ref_name")
    docker_rules.add_argument("--github-output")

    image_notes = subcommands.add_parser("render-image-notes", help="Print release-note image tags for a ref.")
    image_notes.add_argument("tag")
    image_notes.add_argument("image")

    args = parser.parse_args()
    try:
        if args.command == "validate-tag":
            parse_release_tag(args.tag)
        elif args.command == "version":
            print(version_argument(args.value))
        elif args.command == "version-or-dev":
            print(version_or_dev(args.ref_name, args.root))
        elif args.command == "homebrew-formula-name":
            print(homebrew_formula_name(version_argument(args.value)))
        elif args.command == "docker-tag-rules":
            lines = docker_metadata_tag_rules(args.ref_name)
            if args.github_output:
                print_github_multiline(args.github_output, lines)
            else:
                print("\n".join(lines))
        elif args.command == "render-image-notes":
            print("\n".join(render_image_notes(args.tag, args.image)))
        else:
            parser.error(f"unknown command: {args.command}")
    except ValueError as err:
        print(err, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
