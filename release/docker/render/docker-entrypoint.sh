#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  exec ss help
fi

case "$1" in
  ss)
    shift
    exec ss "$@"
    ;;
  bash|sh|/*)
    exec "$@"
    ;;
  *)
    exec ss "$@"
    ;;
esac
