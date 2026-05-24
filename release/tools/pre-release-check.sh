#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: release/tools/pre-release-check.sh [options] vX.Y.Z

Run the local checks that should pass before creating and pushing a release tag.

Options:
  --allow-dirty   Allow tracked working tree changes while debugging this script.
  --skip-docker   Skip the render Docker image build and container run.
  -h, --help      Show this help.

Environment:
  PRE_RELEASE_DOCKER_PLATFORM  Docker platform to build and run. Defaults to linux/amd64.
  PRE_RELEASE_IMAGE            Local Docker image tag. Defaults to ss-render:<tag>-local.
  PRE_RELEASE_DOCKER_TIMEOUT   Seconds to wait for Docker daemon readiness. Defaults to 180.
EOF
}

fail() {
  echo "pre-release-check: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

run() {
  step "$*"
  "$@"
}

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || fail "required command not found: $name"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    fail "required command not found: sha256sum or shasum"
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local pid="$!"
  (
    sleep "$seconds"
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 5
      kill -KILL "$pid" 2>/dev/null || true
    fi
  ) &
  local timer="$!"
  local status=0
  wait "$pid" || status="$?"
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  if [[ "$status" -eq 143 || "$status" -eq 137 ]]; then
    return 124
  fi
  return "$status"
}

tag=""
allow_dirty=false
skip_docker=false

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --allow-dirty)
      allow_dirty=true
      shift
      ;;
    --skip-docker)
      skip_docker=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      if [[ -n "$tag" ]]; then
        fail "multiple tags given: $tag and $1"
      fi
      tag="$1"
      shift
      ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

if [[ -z "$tag" ]]; then
  tag="v$(tr -d '[:space:]' < release/VERSION)"
fi
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "release tag must look like v0.1.0, got $tag"

version="${tag#v}"
commit="$(git rev-parse HEAD)"
short_commit="$(git rev-parse --short HEAD)"
cache_dir="$root/.ss-cache/pre-release-check/$tag"
notes_path="$cache_dir/release-notes.md"
archive_path="$cache_dir/ss-$version.tar.gz"
formula_path="$cache_dir/ss.rb"
vsix_path="$cache_dir/ss-language-support-$tag.vsix"
docker_platform="${PRE_RELEASE_DOCKER_PLATFORM:-linux/amd64}"
docker_image="${PRE_RELEASE_IMAGE:-ss-render:${tag}-local}"
docker_timeout="${PRE_RELEASE_DOCKER_TIMEOUT:-180}"

mkdir -p "$cache_dir"

if [[ "$allow_dirty" != true ]]; then
  git update-index -q --refresh
  git diff-index --quiet HEAD -- || fail "tracked working tree has unstaged changes"
  git diff --cached --quiet || fail "tracked working tree has staged changes"
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  fail "local tag already exists: $tag"
fi

remote_tag_status=0
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 || remote_tag_status="$?"
case "$remote_tag_status" in
  0) fail "remote tag already exists on origin: $tag" ;;
  2) ;;
  *) fail "could not check origin for existing tag $tag" ;;
esac

release_version="$(tr -d '[:space:]' < release/VERSION)"
[[ "$release_version" == "$version" ]] || fail "release/VERSION is $release_version but tag is $tag"

require_command git
require_command zig
require_command node
require_command npm
require_command pkg-config
require_command qpdf
require_command pdftoppm
require_command rsvg-convert
require_command pdflatex
require_command ruby
if [[ "$skip_docker" != true ]]; then
  require_command docker
fi

run pkg-config --exists cairo pangocairo librsvg-2.0

step "release metadata"
release/tools/preflight.py "$tag"
release/tools/changelog-section.py "$tag" > "$notes_path"
test -s "$notes_path"

run scripts/setup-md4c.sh

run zig build test
run zig build -Doptimize=ReleaseSafe -Dversion="$version" -Dcommit="$commit"

step "built ss version"
version_output="$(zig-out/bin/ss --version)"
echo "$version_output"
case "$version_output" in
  *"ss $version ($commit)"*) ;;
  *) fail "unexpected ss --version output for $tag at $commit" ;;
esac

run tests/smoke/project.sh
run node tests/smoke/lsp.mjs
run tests/smoke/render.sh

step "tree-sitter grammar"
(
  cd editor/tree-sitter-ss
  npm ci
  npm test
)

step "VS Code extension"
(
  cd editor/vscode
  npm ci
  npm run compile
  npm run package -- --out "$vsix_path" --allow-missing-repository --skip-license
)
test -s "$vsix_path"

step "source archive and Homebrew formula"
git archive --format=tar --prefix="ss-$version/" "$commit" | gzip -n > "$archive_path"
source_sha256="$(sha256_file "$archive_path")"
release/tools/render-homebrew-formula.py \
  --version "$version" \
  --source-url "https://github.com/abap34/ss/releases/download/$tag/ss-$version.tar.gz" \
  --source-sha256 "$source_sha256" \
  --output "$formula_path"
ruby -c "$formula_path"

if [[ "$skip_docker" == true ]]; then
  echo
  echo "pre-release-check: skipped Docker render image checks"
else
  step "Docker availability"
  run_with_timeout "$docker_timeout" docker info >/dev/null || fail "docker daemon did not respond within ${docker_timeout} seconds"

  step "render Docker image build"
  if docker buildx version >/dev/null 2>&1; then
    docker buildx build \
      --load \
      --platform "$docker_platform" \
      --build-arg "SS_VERSION=$version" \
      --build-arg "SS_COMMIT=$commit" \
      -f release/docker/render/Dockerfile \
      -t "$docker_image" \
      .
  else
    docker build \
      --platform "$docker_platform" \
      --build-arg "SS_VERSION=$version" \
      --build-arg "SS_COMMIT=$commit" \
      -f release/docker/render/Dockerfile \
      -t "$docker_image" \
      .
  fi

  step "render Docker image version"
  docker run --rm --platform "$docker_platform" --entrypoint ss "$docker_image" --version

  step "render Docker image entrypoint"
  container_workspace="$cache_dir/render-pages-workspace"
  rm -rf "$container_workspace"
  mkdir -p "$container_workspace/slides"
  cat > "$container_workspace/slides/release-check.ss" <<'SS'
import std:themes/default

page release_check
cover("Release check", "render image entrypoint", "local")
pageno()
end
SS

  docker run --rm \
    --platform "$docker_platform" \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e SS_INPUT='slides/**/*.ss' \
    -e SS_OUT_DIR=_site \
    -e SS_PDF_DIR=slides \
    -e SS_INDEX_TITLE='Release Check' \
    -e SS_CHECK=true \
    -e SS_WRITE_DUMP=true \
    -v "$container_workspace:/workspace" \
    -w /workspace \
    "$docker_image"

  test -s "$container_workspace/_site/index.html"
  test -s "$container_workspace/_site/manifest.json"
  test -s "$container_workspace/_site/slides/release-check.pdf"
  test -s "$container_workspace/_site/slides/release-check.json"
  qpdf --check "$container_workspace/_site/slides/release-check.pdf" >/dev/null
fi

if [[ "$allow_dirty" != true ]]; then
  git diff --quiet -- . ':(exclude).ss-cache' || fail "tracked files changed while running pre-release check"
fi

echo
echo "pre-release-check: ok $tag at $short_commit"
