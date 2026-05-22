#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
SS_BIN="${SS_BIN:-$ROOT/zig-out/bin/ss}"
FIXTURE="$ROOT/tests/fixtures/project-basic"
CACHE="$ROOT/.ss-cache/project-smoke"

rm -rf "$CACHE"
mkdir -p "$CACHE"

"$SS_BIN" --version >"$CACHE/version.out" 2>"$CACHE/version.err"
test -s "$CACHE/version.out"
test ! -s "$CACHE/version.err"

"$SS_BIN" check "$FIXTURE/slide.ss"
"$SS_BIN" check --project "$FIXTURE"
"$SS_BIN" check --project "$FIXTURE/ss.toml"
(cd "$FIXTURE" && "$SS_BIN" check)

NO_PROJECT="$ROOT/.ss-cache/no-project-smoke"
rm -rf "$NO_PROJECT"
mkdir -p "$NO_PROJECT"
if (cd "$NO_PROJECT" && "$SS_BIN" check >/dev/null 2>"$CACHE/no-input.err"); then
  echo "ss check without input or project unexpectedly passed" >&2
  exit 1
fi
grep -F "missing input path or --project" "$CACHE/no-input.err" >/dev/null

if "$SS_BIN" nope >/dev/null 2>"$CACHE/unknown-command.err"; then
  echo "unknown command unexpectedly passed" >&2
  exit 1
fi

"$SS_BIN" dump "$FIXTURE/slide.ss" "$CACHE/explicit.json"
"$SS_BIN" dump --project "$FIXTURE" --output "$CACHE/project-dir.json"
"$SS_BIN" dump --project "$FIXTURE/ss.toml" --output "$CACHE/project-file.json"
(cd "$FIXTURE" && "$SS_BIN" dump --output "$CACHE/discovered.json")

cmp "$CACHE/explicit.json" "$CACHE/project-dir.json"
cmp "$CACHE/explicit.json" "$CACHE/project-file.json"
cmp "$CACHE/explicit.json" "$CACHE/discovered.json"
test -s "$CACHE/explicit.json"

echo "project-smoke: ok"
