#!/usr/bin/env python3
import argparse
import pathlib
import sys

from release_versions import homebrew_formula_class, homebrew_formula_name, parse_version


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--formula-name", help="Homebrew formula name. Defaults to ss, or ss@<version> for patch releases.")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    try:
        parsed_version = parse_version(args.version)
    except ValueError as err:
        raise SystemExit(str(err))
    formula_name = args.formula_name or homebrew_formula_name(parsed_version.version)
    try:
        formula_class = homebrew_formula_class(formula_name)
    except ValueError as err:
        raise SystemExit(str(err))

    root = pathlib.Path(__file__).resolve().parents[2]
    template = (root / "release" / "homebrew" / "ss.rb.in").read_text(encoding="utf-8")
    replacements = {
        "@FORMULA_CLASS@": formula_class,
        "@VERSION@": parsed_version.version,
        "@SOURCE_URL@": args.source_url,
        "@SOURCE_SHA256@": args.source_sha256,
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
