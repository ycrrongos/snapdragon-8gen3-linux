#!/usr/bin/env bash
# Dump PARF + PCIe SM + PHY golden sample on AOSP while kiwi linked.
# No /dev/mem (CONFIG_DEVMEM=n) — uses msm_pcie debugfs case 12/14.
set -euo pipefail
OUT="${1:-/mnt/data/LOA_Nubia_Z60U/notes/bisect-logs/aosp-parf-gold-$(date +%Y%m%d-%H%M%S).txt}"
serial=$(adb devices | awk 'NR>1 && /device$/{print $1; exit}')
[[ -n "${serial:-}" ]] || { echo "no adb device"; exit 1; }
ADB=(adb -s "$serial")

"${ADB[@]}" root >/dev/null || true
sleep 1
"${ADB[@]}" wait-for-device

"${ADB[@]}" shell '
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
for d in /sys/bus/pci/devices/*; do
  echo on > "$d/power/control" 2>/dev/null || true
done
test -e /sys/kernel/debug/pci-msm/case
'

read_reg() {
  local sel="$1" off="$2"
  "${ADB[@]}" shell "dmesg -c >/dev/null; echo 1 >/sys/kernel/debug/pci-msm/rc_sel; echo $sel >/sys/kernel/debug/pci-msm/base_sel; echo $((off)) >/sys/kernel/debug/pci-msm/wr_offset; echo 12 >/sys/kernel/debug/pci-msm/case; dmesg" \
    | awk -v o="$off" '/value:/{print o, $NF}'
}

{
  echo "=== AOSP PARF gold dump $(date -Iseconds) ==="
  echo "serial=$serial"
  "${ADB[@]}" shell 'getprop ro.build.display.id; getprop ro.boot.slot_suffix; getprop ro.product.name'
  echo
  echo "=== pci / runtime / wlan ==="
  "${ADB[@]}" shell 'for d in /sys/bus/pci/devices/*; do echo -n "$d "; cat $d/power/runtime_status; cat $d/uevent | grep PCI_ID; done; ip link show wlan0 2>&1 | head -2'
  echo
  echo "=== GPIO (case 17) / INFO (case 0) ==="
  "${ADB[@]}" shell 'dmesg -c >/dev/null; echo 17 >/sys/kernel/debug/pci-msm/case; dmesg; dmesg -c >/dev/null; echo 0 >/sys/kernel/debug/pci-msm/case; dmesg'
  echo
  echo "=== PARF key regs (base_sel=1) ==="
  for off in 0x00 0x10 0x14 0x18 0x1c 0x20 0x28 0x2c 0x30 0x40 0x4c 0x50 \
             0x1b0 0x1b4 0x1b8 0x1bc 0x214 0x240 0x2b0 0x350 0x358 0x648 0x64c; do
    read_reg 1 "$off"
  done
  echo
  echo "=== PHY head (base_sel=2) ==="
  for off in 0x00 0x04 0x08 0x0c 0x10 0x14 0x18 0x1c 0x20 0x24 0x28 0x2c; do
    read_reg 2 "$off"
  done
  echo
  echo "=== SM key regs (base_sel=7) ==="
  for off in 0x00 0x04 0x08 0x0c 0x10 0x14 0x18 0x1c 0x20 0x24 0x28 0x2c 0x30 \
             0x1000 0x1004 0x1008 0x100c 0x1040 0x1048 0x1088 0x1090 0x4040 0x4048; do
    read_reg 7 "$off"
  done
  echo
  echo "=== SM full dump (case 14) ==="
  "${ADB[@]}" shell 'dmesg -c >/dev/null; echo 7 >/sys/kernel/debug/pci-msm/base_sel; echo 14 >/sys/kernel/debug/pci-msm/case; sleep 0.5; dmesg'
  echo
  echo "=== still alive ==="
  "${ADB[@]}" shell 'echo OK; ls /sys/bus/pci/devices; cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status'
} | tee "$OUT"

echo "Wrote $OUT"