#!/usr/bin/env bash
set -euo pipefail

script_root="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "$script_root/build.zig" ]]; then
  repo_root="$script_root"
else
  repo_root="$(pwd)"
fi
ss_bin="${SS_BIN:-"$repo_root/zig-out/bin/ss"}"
work_dir="${SS_RENDER_SMOKE_DIR:-"$repo_root/.ss-cache/render-smoke"}"

if [[ ! -x "$ss_bin" ]]; then
  echo "render-smoke: ss binary not found or not executable: $ss_bin" >&2
  echo "render-smoke: run 'zig build' first or set SS_BIN=/path/to/ss" >&2
  exit 2
fi

rm -rf "$work_dir"
rm -rf "$repo_root/.ss-cache/render"
mkdir -p "$work_dir/assets"

cat > "$work_dir/assets/vector.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180" viewBox="0 0 320 180">
  <rect x="1" y="1" width="318" height="178" fill="#f8fbff" stroke="#2f6fb0" stroke-width="2"/>
  <path d="M40 128 L105 56 L160 96 L226 40 L282 118" fill="none" stroke="#d94841" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>
  <text x="28" y="34" font-family="sans-serif" font-size="20" fill="#1f2933">SVG asset</text>
</svg>
SVG

cat > "$work_dir/smoke.ss" <<'SS'
import std:themes/default

page native_render_smoke
let title = head "Native renderer smoke"

let body = text <<
- Bullets must not overlap.
- Japanese text should render: 日本語の本文。
>>
~ body.top == title.bottom - 28
~ body.left == page.left + 110
~ body.width == 1120

let svg_fig = image("assets/vector.svg", 1)
~ svg_fig.top == body.bottom - 34
~ svg_fig.left == page.left + 120
~ svg_fig.width == 320
~ svg_fig.height == 180

pageno()
end
SS

"$ss_bin" check "$work_dir/smoke.ss"
"$ss_bin" render "$work_dir/smoke.ss" "$work_dir/smoke-cold.pdf"
qpdf --check "$work_dir/smoke-cold.pdf" >/dev/null
pdftoppm -png -f 1 -singlefile "$work_dir/smoke-cold.pdf" "$work_dir/smoke-page1" >/dev/null
test -s "$work_dir/smoke-cold.pdf"
test -s "$work_dir/smoke-page1.png"

"$ss_bin" render "$work_dir/smoke.ss" "$work_dir/smoke-warm.pdf"
qpdf --check "$work_dir/smoke-warm.pdf" >/dev/null
test -s "$work_dir/smoke-warm.pdf"

page_cache="$(find "$repo_root/.ss-cache/render/pages" -name 'page-*.pdf' | head -n 1)"
document_cache="$(find "$repo_root/.ss-cache/render/documents" -name 'document-*.pdf' | head -n 1)"
test -n "$page_cache"
test -n "$document_cache"
printf 'not a pdf\n' > "$page_cache"
printf 'not a pdf\n' > "$document_cache"

"$ss_bin" render "$work_dir/smoke.ss" "$work_dir/smoke-recovered.pdf"
qpdf --check "$work_dir/smoke-recovered.pdf" >/dev/null
test -s "$work_dir/smoke-recovered.pdf"

echo "render-smoke: ok $work_dir/smoke-cold.pdf $work_dir/smoke-warm.pdf $work_dir/smoke-recovered.pdf"
