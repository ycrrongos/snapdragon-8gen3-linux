#!/bin/sh
# Run only after cerro-bt-up.sh has been killed.  That script's btmgmt call
# sits in the kernel and makes a concurrent public-addr fail.  Once it is
# gone, the same command used on this handset moves hci0 out of
# HCI_UNCONFIGURED.  btmgmt's own exit code is not the result; read the
# address back from hciconfig.
ADDR=${CERRO_BT_PUBLIC_ADDR:-02:00:95:0B:4D:FF}
log() { echo "cerro-bt-configure: $*" >/dev/kmsg 2>/dev/null || echo "cerro-bt-configure: $*"; }

i=0
while [ "$i" -lt 40 ]; do
  if dmesg 2>/dev/null | grep -q 'QCA setup on UART is completed' \
      && [ -e /sys/class/bluetooth/hci0 ]; then
    break
  fi
  sleep 1
  i=$((i + 1))
done

if hciconfig hci0 2>/dev/null | grep -q "$ADDR"; then
  timeout -k 2 8 bluetoothctl power on >/dev/kmsg 2>&1 || true
  log "address already set"
  exit 0
fi

# bluetoothd holds the mgmt socket on an unconfigured controller, so
# public-addr does not return.  Stop it, set the address, start it again.
systemctl stop bluetooth.service
sleep 1
timeout -k 3 20 btmgmt -i 0 public-addr "$ADDR" >/dev/kmsg 2>&1 || true
systemctl start bluetooth.service
i=0
while [ "$i" -lt 15 ]; do
  if hciconfig hci0 2>/dev/null | grep -q "$ADDR"; then
    timeout -k 2 8 bluetoothctl power on >/dev/kmsg 2>&1 || true
    log "powered"
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done
log "address did not change"
exit 1
