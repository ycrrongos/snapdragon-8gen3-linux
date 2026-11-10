#!/bin/bash
# Desktop / CLI: switch from Linux (slot B) to Android (slot A) and reboot.
# Safe for polkit/pkexec: only qbootctl slot switch, no partition writes.
set -euo pipefail

Q=/usr/bin/qbootctl
if [[ ! -x $Q ]]; then
  zenity --error --text="缺少 qbootctl" 2>/dev/null || notify-send "Cerro" "缺少 qbootctl" 2>/dev/null || echo "missing qbootctl" >&2
  exit 1
fi

if [[ $(id -u) -ne 0 ]]; then
  exec pkexec --disable-internal-agent "$0" "$@"
fi

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
echo "=== Cerro: Linux → Android (slot A) ==="
"$Q" -a 2>&1 || true
"$Q" -s 0
sync
if command -v zenity >/dev/null; then
  zenity --info --timeout=2 --text="正在切换到 Android…" 2>/dev/null || true
elif command -v notify-send >/dev/null; then
  notify-send "Cerro" "正在切换到 Android…" 2>/dev/null || true
fi
reboot
