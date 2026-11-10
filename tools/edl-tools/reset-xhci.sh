#!/bin/sh
set -eux
# Dead controller was 0000:00:14.0 (usb3/usb4) — remove + rescan
if [ -e /sys/bus/pci/devices/0000:00:14.0 ]; then
  echo 1 > /sys/bus/pci/devices/0000:00:14.0/remove || true
  sleep 1
fi
echo 1 > /sys/bus/pci/rescan
sleep 2
# Reload xhci modules as backup
modprobe -r xhci_pci 2>/dev/null || true
modprobe -r xhci_hcd 2>/dev/null || true
modprobe xhci_hcd
modprobe xhci_pci
sleep 2
echo '==== lsusb ===='
lsusb
echo '==== journal ===='
journalctl -k -n 15 --no-pager | grep -iE 'xhci|usb [34]-' || true
