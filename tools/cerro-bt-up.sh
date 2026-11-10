#!/bin/sh
# Bring up the Cerro WCN7850 controller without deprecated hciconfig.
KVER=$(uname -r)
BASE=/lib/modules/$KVER
BT_INDEX=${CERRO_BT_INDEX:-0}
BT_DEVICE=${CERRO_BT_DEVICE:-hci0}
BT_PUBLIC_ADDR=${CERRO_BT_PUBLIC_ADDR:-02:00:95:0B:4D:FF}

log() { echo "cerro-bt: $*" >/dev/kmsg 2>/dev/null || echo "cerro-bt: $*"; }
loaded() { lsmod 2>/dev/null | grep -q "^$1 "; }
load1() {
  m=$1
  loaded "$m" && return 0
  if [ -f "$BASE/${m}.ko" ]; then
    insmod "$BASE/${m}.ko" && return 0
  fi
  f=$(find "$BASE" -name "${m}.ko" 2>/dev/null | head -1)
  [ -n "$f" ] || return 1
  insmod "$f"
}

for m in rfkill kpp ecc ecdh_generic bluetooth btbcm btqca hci_uart; do
  if load1 "$m"; then
    log "loaded $m"
  else
    log "warn: load $m failed"
  fi
done

# Keep under systemd TimeoutStartSec=15 (was 40s + btmgmt retries → boot stall).
i=0
while [ "$i" -lt 8 ]; do
  [ -e "/sys/class/bluetooth/$BT_DEVICE" ] && break
  sleep 1
  i=$((i + 1))
done
rfkill unblock bluetooth 2>/dev/null || true

# Do not call btmgmt here.  On an unconfigured WCN7850 that ioctl does not
# return, and a following address command fails until the controller is idle.
# cerro-bt-configure.service sets the public address after this script exits.
log "modules ready; address is configured by cerro-bt-configure"
exit 0
