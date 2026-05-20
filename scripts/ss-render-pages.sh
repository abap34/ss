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

html_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  printf '%s' "$value"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

if [[ "$clean" == "true" ]]; then
  rm -rf "$out_dir"
fi

mkdir -p "$out_dir/$pdf_dir"
manifest="$out_dir/.ss-render-pages.tsv"
: > "$manifest"

shopt -s globstar nullglob

declare -A seen=()
sources=()
while IFS= read -r line || [[ -n "$line" ]]; do
  IFS=',' read -ra parts <<< "$line"
  for raw_pattern in "${parts[@]}"; do
    pattern="$(trim "$raw_pattern")"
    [[ -n "$pattern" ]] || continue
    while IFS= read -r path; do
      [[ -f "$path" && "$path" == *.ss ]] || continue
      normalized="${path%/}"
      if [[ -z "${seen[$normalized]:-}" ]]; then
        seen[$normalized]=1
        sources+=("$normalized")
      fi
    done < <(compgen -G "$pattern" || true)
  done
done <<< "$input"

if [[ "${#sources[@]}" -eq 0 ]]; then
  echo "ss-render-pages: no .ss files matched '$input'" >&2
  exit 2
fi

mapfile -t sources < <(printf '%s\n' "${sources[@]}" | sort)

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
  render_cmd=(ss render "$src" "$pdf_path")
  dump_cmd=(ss dump "$src" "$out_dir/$pdf_dir/$stem.json")

  if [[ -n "$asset_base_dir" ]]; then
    check_cmd+=(--asset-base-dir "$asset_base_dir")
    render_cmd+=(--asset-base-dir "$asset_base_dir")
    dump_cmd+=(--asset-base-dir "$asset_base_dir")
  fi

  if [[ "$check" == "true" ]]; then
    echo "check  $src"
    "${check_cmd[@]}"
  fi

  echo "render $src -> $pdf_path"
  "${render_cmd[@]}"

  if [[ "$write_dump" == "true" ]]; then
    echo "dump   $src -> $out_dir/$pdf_dir/$stem.json"
    "${dump_cmd[@]}"
  fi

  printf '%s\t%s\n' "$pdf_rel" "$src" >> "$manifest"
done

{
  cat <<HTML
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>$(html_escape "$index_title")</title>
    <style>
      :root {
        color-scheme: light dark;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }
      body {
        margin: 0;
        padding: 48px;
        line-height: 1.5;
      }
      main {
        max-width: 760px;
      }
      h1 {
        margin: 0 0 24px;
        font-size: 32px;
      }
      ul {
        list-style: none;
        padding: 0;
      }
      li {
        border-top: 1px solid color-mix(in srgb, currentColor 18%, transparent);
        padding: 14px 0;
      }
      a {
        font-weight: 650;
      }
      span {
        display: block;
        margin-top: 4px;
        opacity: 0.7;
        font-size: 14px;
      }
    </style>
  </head>
  <body>
    <main>
      <h1>$(html_escape "$index_title")</h1>
      <ul>
HTML
  while IFS=$'\t' read -r pdf_rel src; do
    [[ -n "$pdf_rel" ]] || continue
    pdf_name="$(basename "$pdf_rel")"
    printf '        <li><a href="%s">%s</a><span>%s</span></li>\n' \
      "$(html_escape "$pdf_rel")" \
      "$(html_escape "$pdf_name")" \
      "$(html_escape "$src")"
  done < "$manifest"
  cat <<HTML
      </ul>
    </main>
  </body>
</html>
HTML
} > "$out_dir/index.html"

{
  printf '[\n'
  first=true
  while IFS=$'\t' read -r pdf_rel src; do
    [[ -n "$pdf_rel" ]] || continue
    if [[ "$first" == "true" ]]; then
      first=false
    else
      printf ',\n'
    fi
    printf '  {"pdf": "%s", "source": "%s"}' \
      "$(json_escape "$pdf_rel")" \
      "$(json_escape "$src")"
  done < "$manifest"
  printf '\n]\n'
} > "$out_dir/manifest.json"

echo "wrote $out_dir/index.html"
echo "wrote $out_dir/manifest.json"
