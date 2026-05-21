#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
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
doctor="$("$SS_BIN" doctor --project "$FIXTURE" 2>&1)"
printf '%s\n' "$doctor" | grep -F "ss doctor" >/dev/null
printf '%s\n' "$doctor" | grep -F "project:" >/dev/null
printf '%s\n' "$doctor" | grep -F "render tools:" >/dev/null

INIT_FIXTURE="$ROOT/.ss-cache/init-smoke"
rm -rf "$INIT_FIXTURE"
"$SS_BIN" init "$INIT_FIXTURE"
test -f "$INIT_FIXTURE/ss.toml"
test -f "$INIT_FIXTURE/slide.ss"
grep -F 'entry = "slide.ss"' "$INIT_FIXTURE/ss.toml" >/dev/null
"$SS_BIN" check --project "$INIT_FIXTURE"
if "$SS_BIN" init "$INIT_FIXTURE" >/dev/null 2>&1; then
  echo "ss init unexpectedly overwrote an existing project" >&2
  exit 1
fi
"$SS_BIN" init "$INIT_FIXTURE" --force >/dev/null

"$SS_BIN" dump "$FIXTURE/slide.ss" "$CACHE/explicit.json"
"$SS_BIN" dump --project "$FIXTURE" --output "$CACHE/project-dir.json"
"$SS_BIN" dump --project "$FIXTURE/ss.toml" --output "$CACHE/project-file.json"
(cd "$FIXTURE" && "$SS_BIN" dump --output "$CACHE/discovered.json")

cmp "$CACHE/explicit.json" "$CACHE/project-dir.json"
cmp "$CACHE/explicit.json" "$CACHE/project-file.json"
cmp "$CACHE/explicit.json" "$CACHE/discovered.json"

CACHE_STATS="$ROOT/.ss-cache/cache-stats-smoke"
rm -rf "$CACHE_STATS"
mkdir -p "$CACHE_STATS/.ss-cache/render/math" "$CACHE_STATS/.ss-cache/render/assets"
printf abc > "$CACHE_STATS/.ss-cache/render/math/a.cache"
printf 12345 > "$CACHE_STATS/.ss-cache/render/assets/b.cache"
stats="$(cd "$CACHE_STATS" && "$SS_BIN" cache stats 2>&1)"
printf '%s\n' "$stats" | grep -F "render cache: .ss-cache/render" >/dev/null
printf '%s\n' "$stats" | grep -F "files: 2" >/dev/null
printf '%s\n' "$stats" | grep -F "directories: 2" >/dev/null
printf '%s\n' "$stats" | grep -F "size: 8 B" >/dev/null

rm -rf "$CACHE_STATS/.ss-cache/render"
stats="$(cd "$CACHE_STATS" && "$SS_BIN" cache stats 2>&1)"
printf '%s\n' "$stats" | grep -F "files: 0" >/dev/null
printf '%s\n' "$stats" | grep -F "directories: 0" >/dev/null
printf '%s\n' "$stats" | grep -F "size: 0 B" >/dev/null
(cd "$CACHE_STATS" && "$SS_BIN" cache clear >/dev/null 2>&1)

if [ "$RUN_RENDER" = "1" ]; then
  "$SS_BIN" render "$FIXTURE/slide.ss" "$CACHE/explicit.pdf"
  "$SS_BIN" render --project "$FIXTURE" --output "$CACHE/project-dir.pdf"
  "$SS_BIN" render --project "$FIXTURE/ss.toml" --output "$CACHE/project-file.pdf"
  (cd "$FIXTURE" && "$SS_BIN" render --output "$CACHE/discovered.pdf")
fi
