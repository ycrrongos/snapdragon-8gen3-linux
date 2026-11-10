#!/bin/sh
# Read-only DP hotplug capture. Run on the phone as root over Wi-Fi SSH.
set -eu
duration=${1:-900}
case "$duration" in ''|*[!0-9]*) echo 'duration must be seconds' >&2; exit 2;; esac
[ "$duration" -ge 2 ] && [ "$duration" -le 3600 ] || exit 2
[ "$(id -u)" -eq 0 ] || { echo 'run as root for kernel journal' >&2; exit 1; }
umask 077
out=$(mktemp -d /tmp/cerro-dp-capture.XXXXXX)
printf '%s\n' "$out" > /tmp/cerro-dp-capture.latest
cat /proc/sys/kernel/random/boot_id > "$out/boot-id"
uname -a > "$out/kernel"
lsmod > "$out/modules"
journalctl -k -b --no-pager -o short-monotonic > "$out/kernel-before.log"
journalctl -k -f -n 0 --no-pager -o short-monotonic > "$out/kernel-follow.log" 2>&1 &
journal_pid=$!
cleanup() {
    kill "$journal_pid" 2>/dev/null || true
    wait "$journal_pid" 2>/dev/null || true
    date -Is > "$out/stopped"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$out"
end=$(( $(date +%s) + duration ))
while [ "$(date +%s)" -lt "$end" ]; do
    {
        date -Is
        cat /proc/sys/kernel/random/boot_id /proc/uptime
        for node in /sys/class/typec/*; do
            [ -e "$node" ] || continue
            printf 'TYPEC %s\n' "$node"
            # Follow the class entry only; sysfs device/subsystem backlinks loop.
            find -H "$node" -maxdepth 3 -type f \( -name data_role -o -name power_role -o -name orientation -o -name active -o -name svid -o -name mode -o -name pin_assignment -o -name configuration -o -name vdo \) -print -exec cat {} \; || printf 'TYPEC read failed (hotplug race possible)\n'
        done
        for node in /sys/class/drm/card*-DP-* /sys/class/drm/card*-DSI-*; do
            [ -e "$node" ] || continue
            printf 'DRM %s\n' "$node"
            for attr in status enabled modes; do
                printf '%s: ' "$attr"
                cat "$node/$attr" || printf 'read failed\n'
            done
            printf 'edid-bytes: '
            wc -c < "$node/edid" || printf 'read failed\n'
        done
        for role in /sys/class/usb_role/*/role; do
            [ -f "$role" ] || continue
            printf '%s: ' "$role"
            cat "$role" || printf 'read failed\n'
        done
    } >> "$out/snapshots.log" 2>&1
    sleep 2
done
