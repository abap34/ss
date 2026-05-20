#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
  <rect x="1" y="1" width="318" height="178" rx="18" fill="#f8fbff" stroke="#2f6fb0" stroke-width="2"/>
  <path d="M40 128 L105 56 L160 96 L226 40 L282 118" fill="none" stroke="#d94841" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="105" cy="56" r="10" fill="#2f6fb0"/>
  <circle cx="226" cy="40" r="10" fill="#2f6fb0"/>
  <text x="28" y="34" font-family="sans-serif" font-size="20" fill="#1f2933">SVG asset</text>
</svg>
SVG

rsvg-convert -f pdf -o "$work_dir/assets/vector.pdf" "$work_dir/assets/vector.svg"

cat > "$work_dir/smoke.ss" <<'SS'
import std:themes/default

document
  document_background("0.96,0.93,0.82")
  use_math_package("stmaryrd")
end

page native_render_smoke
let title = slide_title "Native renderer smoke"

let body = text <<
- Bullets must not overlap, even with inline math $\mathcal{C}(P) \subseteq \mathcal{C}^{\sharp}(P)$ and emoji 👩‍💻🇯🇵.
  - Nested bullets also advance correctly: $\alpha \sqcup \beta$.
- Japanese text, font fallback, and inline LaTeX should coexist.
>>
set_prop(body, "text_color", "0.82,0.06,0.12")
body.top == title.bottom - 28
body.left == page.left + 110
body.width == 1120

let eq = tex <<
\begin{aligned}
A_0 &= \bigsqcup_{s_i \in \text{Pred}(u)} s_i \\
\llbracket s \rrbracket(x) &= x \sqcup f_s(x)
\end{aligned}
>>
set_prop(eq, "text_color", "0.82,0.06,0.12")
eq.top == body.bottom - 28
eq.left == page.left + 120
eq.width == 700
eq.height == 150

let svg_fig = image("assets/vector.svg", 1)
svg_fig.top == eq.bottom - 34
svg_fig.left == page.left + 120
svg_fig.width == 320
svg_fig.height == 180

let pdf_fig = pdf("assets/vector.pdf", 1)
pdf_fig.top == svg_fig.top
pdf_fig.left == svg_fig.right + 48
pdf_fig.width == 320
pdf_fig.height == 180

page_no()
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

echo "render-smoke: ok $work_dir/smoke-cold.pdf $work_dir/smoke-warm.pdf"
