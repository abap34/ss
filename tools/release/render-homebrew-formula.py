#!/usr/bin/env python3
import argparse
import pathlib
import re
import sys


MD4C_SHA256 = "ecbd85292465df929839897e314d809b5c8b267e20c4e5e24d51a1602d16d99a"


def read_md4c_commit(root: pathlib.Path) -> str:
    setup = (root / "scripts" / "setup-md4c.sh").read_text(encoding="utf-8")
    match = re.search(r'^MD4C_COMMIT="([^"]+)"', setup, re.MULTILINE)
    if not match:
        raise SystemExit("scripts/setup-md4c.sh does not define MD4C_COMMIT")
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parents[2]
    template = (root / "packaging" / "homebrew" / "ss.rb.in").read_text(encoding="utf-8")
    replacements = {
        "@SOURCE_URL@": args.source_url,
        "@SOURCE_SHA256@": args.source_sha256,
        "@MD4C_COMMIT@": read_md4c_commit(root),
        "@MD4C_SHA256@": MD4C_SHA256,
    }
    rendered = template
    for needle, value in replacements.items():
        rendered = rendered.replace(needle, value)

    if "@" in rendered:
        raise SystemExit("unexpanded placeholder remains in Homebrew formula")

    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
