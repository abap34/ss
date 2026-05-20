#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SS_BIN="${SS_BIN:-$ROOT/zig-out/bin/ss}"
FIXTURE="$ROOT/tests/fixtures/project-basic"
CACHE="$ROOT/.ss-cache/project-smoke"
RUN_RENDER=0

if [ "${1:-}" = "--render" ] || [ "${SS_PROJECT_SMOKE_RENDER:-0}" = "1" ]; then
  RUN_RENDER=1
fi

mkdir -p "$CACHE"

"$SS_BIN" check "$FIXTURE/slide.ss"
"$SS_BIN" check --project "$FIXTURE"
"$SS_BIN" check --project "$FIXTURE/ss.toml"

(cd "$FIXTURE" && "$SS_BIN" check)

"$SS_BIN" dump "$FIXTURE/slide.ss" "$CACHE/explicit.json"
"$SS_BIN" dump --project "$FIXTURE" --output "$CACHE/project-dir.json"
"$SS_BIN" dump --project "$FIXTURE/ss.toml" --output "$CACHE/project-file.json"
(cd "$FIXTURE" && "$SS_BIN" dump --output "$CACHE/discovered.json")

cmp "$CACHE/explicit.json" "$CACHE/project-dir.json"
cmp "$CACHE/explicit.json" "$CACHE/project-file.json"
cmp "$CACHE/explicit.json" "$CACHE/discovered.json"

if [ "$RUN_RENDER" = "1" ]; then
  "$SS_BIN" render "$FIXTURE/slide.ss" "$CACHE/explicit.pdf"
  "$SS_BIN" render --project "$FIXTURE" --output "$CACHE/project-dir.pdf"
  "$SS_BIN" render --project "$FIXTURE/ss.toml" --output "$CACHE/project-file.pdf"
  (cd "$FIXTURE" && "$SS_BIN" render --output "$CACHE/discovered.pdf")
fi
