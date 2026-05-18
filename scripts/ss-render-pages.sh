#!/usr/bin/env bash
set -euo pipefail

input="${SS_INPUT:-slides/**/*.ss}"
out_dir="${SS_OUT_DIR:-_site}"
pdf_dir="${SS_PDF_DIR:-slides}"
index_title="${SS_INDEX_TITLE:-Slides}"
asset_base_dir="${SS_ASSET_BASE_DIR:-}"
clean="${SS_CLEAN:-true}"
check="${SS_CHECK:-true}"
write_dump="${SS_WRITE_DUMP:-false}"
python_bin="${SS_PYTHON:-python3}"
pdf_backend="${SS_PDF_BACKEND:-/opt/ss-runtime/src/render/pdf_backend.py}"

if [[ ! -f "$pdf_backend" ]]; then
  echo "ss-render-pages: PDF backend not found: $pdf_backend" >&2
  exit 2
fi

if [[ "$clean" == "true" ]]; then
  rm -rf "$out_dir"
fi

mkdir -p "$out_dir/$pdf_dir"
manifest="$out_dir/.ss-render-pages.tsv"
: > "$manifest"

mapfile -d '' sources < <(
  python3 - "$input" <<'PY'
import glob
import os
import sys

raw = sys.argv[1]
patterns = []
for line in raw.splitlines():
    for part in line.split(","):
        part = part.strip()
        if part:
            patterns.append(part)

seen = set()
matches = []
for pattern in patterns:
    for path in glob.glob(pattern, recursive=True):
        if not os.path.isfile(path):
            continue
        if not path.endswith(".ss"):
            continue
        normalized = os.path.normpath(path)
        if normalized in seen:
            continue
        seen.add(normalized)
        matches.append(normalized)

if not matches:
    print(f"ss-render-pages: no .ss files matched {raw!r}", file=sys.stderr)
    sys.exit(2)

for path in sorted(matches):
    sys.stdout.buffer.write(path.encode("utf-8") + b"\0")
PY
)

declare -A outputs=()

for src in "${sources[@]}"; do
  stem="$(basename "$src" .ss)"
  pdf_path="$out_dir/$pdf_dir/$stem.pdf"
  pdf_rel="$pdf_dir/$stem.pdf"

  if [[ -n "${outputs[$pdf_path]:-}" ]]; then
    echo "ss-render-pages: output collision for $pdf_path from $src and ${outputs[$pdf_path]}" >&2
    exit 2
  fi
  outputs[$pdf_path]="$src"

  mkdir -p "$(dirname "$pdf_path")"

  check_cmd=(ss check "$src")
  tmp_json="$(mktemp "${TMPDIR:-/tmp}/ss-render-pages.XXXXXX.json")"
  dump_cmd=(ss dump "$src" "$tmp_json")
  backend_asset_base="$(dirname "$src")"
  if [[ "$backend_asset_base" == "." ]]; then
    backend_asset_base="."
  fi

  if [[ -n "$asset_base_dir" ]]; then
    check_cmd+=(--asset-base-dir "$asset_base_dir")
    dump_cmd+=(--asset-base-dir "$asset_base_dir")
    backend_asset_base="$asset_base_dir"
  fi

  if [[ "$check" == "true" ]]; then
    echo "check  $src"
    "${check_cmd[@]}"
  fi

  echo "render $src -> $pdf_path"
  "${dump_cmd[@]}"
  "$python_bin" "$pdf_backend" "$tmp_json" "$pdf_path" "$backend_asset_base"

  if [[ "$write_dump" == "true" ]]; then
    echo "dump   $src -> $out_dir/$pdf_dir/$stem.json"
    cp "$tmp_json" "$out_dir/$pdf_dir/$stem.json"
  fi

  rm -f "$tmp_json"

  printf '%s\t%s\n' "$pdf_rel" "$src" >> "$manifest"
done

python3 - "$out_dir" "$index_title" "$manifest" <<'PY'
import html
import json
import sys
from pathlib import Path

out_dir = Path(sys.argv[1])
title = sys.argv[2]
manifest = Path(sys.argv[3])

items = []
for line in manifest.read_text(encoding="utf-8").splitlines():
    if not line:
        continue
    pdf, src = line.split("\t", 1)
    items.append({"pdf": pdf, "source": src})

links = "\n".join(
    f'      <li><a href="{html.escape(item["pdf"], quote=True)}">{html.escape(Path(item["pdf"]).name)}</a>'
    f'<span>{html.escape(item["source"])}</span></li>'
    for item in items
)

page = f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{html.escape(title)}</title>
    <style>
      :root {{
        color-scheme: light dark;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }}
      body {{
        margin: 0;
        padding: 48px;
        line-height: 1.5;
      }}
      main {{
        max-width: 760px;
      }}
      h1 {{
        margin: 0 0 24px;
        font-size: 32px;
      }}
      ul {{
        list-style: none;
        padding: 0;
      }}
      li {{
        border-top: 1px solid color-mix(in srgb, currentColor 18%, transparent);
        padding: 14px 0;
      }}
      a {{
        font-weight: 650;
      }}
      span {{
        display: block;
        margin-top: 4px;
        opacity: 0.7;
        font-size: 14px;
      }}
    </style>
  </head>
  <body>
    <main>
      <h1>{html.escape(title)}</h1>
      <ul>
{links}
      </ul>
    </main>
  </body>
</html>
"""

(out_dir / "index.html").write_text(page, encoding="utf-8")
(out_dir / "manifest.json").write_text(json.dumps(items, indent=2) + "\n", encoding="utf-8")
PY

echo "wrote $out_dir/index.html"
echo "wrote $out_dir/manifest.json"
