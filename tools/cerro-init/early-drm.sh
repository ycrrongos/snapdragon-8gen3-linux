#!/bin/busybox ash
# Satisfy the existing DRM/DP bridge dependencies before initramfs boot text.
set -eu
log() { echo "[cerro-early-drm] $*" > /dev/kmsg; }
trap 'rc=$?; [ "$rc" -eq 0 ] || log "FAIL rc=$rc (rootfs may continue; early display not ready)"' EXIT

log begin
# These dependencies already exist in the proven base cpio. They register
# protocol helpers; ADSP startup and battery/UCSI services remain on their path.
for name in qmi_helpers qcom_pdr_msg pdr_interface; do
    modprobe "$name"
done
for file in aux-hpd-bridge pmic_glink wcd939x-usbss pmic_glink_altmode; do
    insmod "/cerro-early-drm/$file.ko"
done

# Wait for the actual async DRM bind, not an unrelated service or fixed delay.
for n in $(seq 1 50); do
    if [ -c /dev/fb0 ]; then
        log "ready fb0"
        exit 0
    fi
    sleep 0.1
done
log "FAIL fb0 did not appear"
exit 1
