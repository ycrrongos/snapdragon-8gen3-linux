#!/usr/bin/env bash
# Wait until phone shows as Qualcomm 9008, then run a command.
set -euo pipefail
echo "等待 05c6:9008 ..."
echo "进法: 关机后同时按住 音量+ 和 音量-，插入 USB（或保持按住电源键重置后再按双音量）"
for i in $(seq 1 120); do
  if lsusb | grep -qi '05c6:9008'; then
    echo "检测到 9008 ($(date +%H:%M:%S))"
    lsusb | grep -i 9008
    exec "$@"
  fi
  if (( i % 5 == 0 )); then
    cur=$(lsusb | grep -iE '19d2|05c6' | tr '\n' ' ' || true)
    echo "[$i] 尚未 9008: ${cur:-none}"
  fi
  sleep 2
done
echo "超时：仍未进入 9008"
exit 1
