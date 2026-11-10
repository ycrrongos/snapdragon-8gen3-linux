#!/usr/bin/env bash
# Flash local AOSP cerro images via fastbootd. Does NOT wipe until --wipe.
# Usage: flash-aosp-fastbootd.sh [--wipe] [/path/to/product/cerro]
set -euo pipefail
FB="${FB:-fastboot}"
WIPE=0
IX=/mnt/data/aosp/out/target/product/cerro
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wipe) WIPE=1; shift ;;
    *) IX="$1"; shift ;;
  esac
done
ARGS=()
if [[ "$WIPE" == 1 ]]; then
  ARGS+=(--wipe)
fi
exec "$(cd "$(dirname "$0")" && pwd)/flash-infinityx-fastbootd.sh" "${ARGS[@]}" "$IX"
