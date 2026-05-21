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
"$SS_BIN" dump "$FIXTURE/slide.ss" >"$CACHE/stdout.json" 2>"$CACHE/stdout.err"

cmp "$CACHE/explicit.json" "$CACHE/project-dir.json"
cmp "$CACHE/explicit.json" "$CACHE/project-file.json"
cmp "$CACHE/explicit.json" "$CACHE/discovered.json"
cmp "$CACHE/explicit.json" "$CACHE/stdout.json"
test -s "$CACHE/stdout.err"

RESOLVER_FIXTURE="$ROOT/.ss-cache/resolver-smoke"
rm -rf "$RESOLVER_FIXTURE"
mkdir -p "$RESOLVER_FIXTURE/current" "$RESOLVER_FIXTURE/outside"
cat > "$RESOLVER_FIXTURE/current/ss.toml" <<'SS'
[project]
entry = "slide.ss"
asset_base_dir = "."
SS
cat > "$RESOLVER_FIXTURE/current/slide.ss" <<'SS'
import std:themes/default
import "./parts.ss"

page current
  current_fn()
end
SS
cat > "$RESOLVER_FIXTURE/current/parts.ss" <<'SS'
fn current_fn() -> object
  return text("current")
end
SS
cat > "$RESOLVER_FIXTURE/outside/slide.ss" <<'SS'
import std:themes/default
import "./parts.ss"

page outside
  outside_fn()
end
SS
cat > "$RESOLVER_FIXTURE/outside/parts.ss" <<'SS'
fn outside_fn() -> object
  return text("outside")
end
SS
(cd "$RESOLVER_FIXTURE/current" && "$SS_BIN" check "$RESOLVER_FIXTURE/outside/slide.ss")

"$SS_BIN" watch check --project "$FIXTURE" --interval-ms 100 >"$CACHE/watch.out" 2>"$CACHE/watch.err" &
watch_pid=$!
sleep 0.4
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
grep -F "watch: check $FIXTURE/slide.ss every 100ms" "$CACHE/watch.err" >/dev/null

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
