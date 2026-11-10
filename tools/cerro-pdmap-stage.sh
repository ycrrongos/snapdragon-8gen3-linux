#!/bin/sh
# Stage the stock modem protection-domain map before pd-mapper snapshots it.
set -eu

SOURCE_DEVICE=/dev/disk/by-partlabel/modem_a
MOUNT_DIR=/run/cerro-pdmap-modem-a
DEST_DIR=/lib/firmware/qcom/sm8650

i=0
while [ ! -b "$SOURCE_DEVICE" ] && [ "$i" -lt 50 ]; do
  sleep 0.2
  i=$((i + 1))
done
if [ ! -b "$SOURCE_DEVICE" ]; then
  echo "cerro-pdmap-stage: missing $SOURCE_DEVICE" >&2
  exit 1
fi

mkdir -p "$MOUNT_DIR" "$DEST_DIR"
if mountpoint -q "$MOUNT_DIR"; then
  echo "cerro-pdmap-stage: unexpected existing mount at $MOUNT_DIR" >&2
  exit 1
fi

mounted=0
tmp_file=
cleanup() {
  if [ -n "$tmp_file" ]; then
    rm -f "$tmp_file"
  fi
  if [ "$mounted" = 1 ]; then
    umount "$MOUNT_DIR" 2>/dev/null || true
  fi
  rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mount -t vfat -o ro,nosuid,nodev,noexec "$SOURCE_DEVICE" "$MOUNT_DIR"
mounted=1

for map_name in modemr.jsn; do
  source_file="$MOUNT_DIR/image/$map_name"
  dest_file="$DEST_DIR/$map_name"
  if [ ! -f "$source_file" ]; then
    echo "cerro-pdmap-stage: missing stock map $source_file" >&2
    exit 1
  fi
  if [ -f "$dest_file" ] && cmp -s "$source_file" "$dest_file"; then
    continue
  fi

  tmp_file="$DEST_DIR/.${map_name}.cerro-pdmap-stage.$$"
  install -m 0644 "$source_file" "$tmp_file"
  cmp "$source_file" "$tmp_file"
  mv -f "$tmp_file" "$dest_file"
  tmp_file=
done

echo "cerro-pdmap-stage: stock modem map verified"
