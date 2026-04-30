#!/usr/bin/env sh
set -eu

MD4C_REPO_URL="https://github.com/mity/md4c.git"
MD4C_COMMIT="472c417005c2c71b8617de4f7b8d6b30411d78f4"

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dest="$repo_root/third_party/md4c"

mkdir -p "$repo_root/third_party"

if [ -d "$dest/.git" ]; then
  current_commit=$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)
  if [ "$current_commit" = "$MD4C_COMMIT" ]; then
    echo "MD4C already installed at $MD4C_COMMIT"
    exit 0
  fi
else
  rm -rf "$dest"
  git init -q "$dest"
  git -C "$dest" remote add origin "$MD4C_REPO_URL"
fi

git -C "$dest" fetch --depth 1 origin "$MD4C_COMMIT"
git -C "$dest" checkout -q --detach "$MD4C_COMMIT"

echo "Installed MD4C at $MD4C_COMMIT"
