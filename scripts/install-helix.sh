#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
HELIX_CONFIG="${HELIX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/helix}"
HELIX_RUNTIME="${HELIX_RUNTIME:-$HELIX_CONFIG/runtime}"
LANGUAGES="$HELIX_CONFIG/languages.toml"
QUERIES="$HELIX_RUNTIME/queries/ss"
SS_BIN="${SS_BIN:-$(command -v ss || printf '%s/zig-out/bin/ss' "$ROOT")}"

START="# BEGIN ss editor integration"
END="# END ss editor integration"

mkdir -p "$HELIX_CONFIG" "$QUERIES"
touch "$LANGUAGES"

tmp="$(mktemp)"
awk -v start="$START" -v end="$END" '
  $0 == start { skip = 1; next }
  $0 == end { skip = 0; next }
  !skip { print }
' "$LANGUAGES" > "$tmp"

cat >> "$tmp" <<EOF

$START
[language-server.ss]
command = "$SS_BIN"
args = ["lsp"]

[[language]]
name = "ss"
scope = "source.ss"
file-types = ["ss"]
roots = ["ss.toml", ".git"]
comment-token = ";;"
language-servers = ["ss"]
indent = { tab-width = 2, unit = "  " }
auto-format = false

[[grammar]]
name = "ss"
source = { path = "$ROOT/tree-sitter-ss" }
$END
EOF

mv "$tmp" "$LANGUAGES"

cp "$ROOT/tree-sitter-ss/queries/highlights.scm" "$QUERIES/highlights.scm"
cp "$ROOT/tree-sitter-ss/queries/locals.scm" "$QUERIES/locals.scm"
cp "$ROOT/tree-sitter-ss/queries/folds.scm" "$QUERIES/folds.scm"
cp "$ROOT/editor/helix/queries/ss/indents.scm" "$QUERIES/indents.scm"
cp "$ROOT/editor/helix/queries/ss/textobjects.scm" "$QUERIES/textobjects.scm"
cp "$ROOT/editor/helix/queries/ss/tags.scm" "$QUERIES/tags.scm"
cp "$ROOT/editor/helix/queries/ss/rainbows.scm" "$QUERIES/rainbows.scm"

if command -v hx >/dev/null 2>&1; then
  hx --grammar build ss
  hx --health ss
else
  printf 'hx was not found on PATH; copied config and queries only.\n' >&2
fi
