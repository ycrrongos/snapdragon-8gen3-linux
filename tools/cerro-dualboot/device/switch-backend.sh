#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Same-slot boot/dtbo swap, shared by Android root and Linux polkit apps.
# Live acceptance status is recorded in README.md; writes always require validation.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin:/system/bin:/system/xbin:/vendor/bin
export PATH
ACTION=${1:-status}
MOUNT_POINT= LOCKED=0 STATE= OS= SLOT= OTHER= SERIAL= ROOT_UUID= PARTDIR=
fail() { echo "错误：$*" >&2; exit 1; }
log() { echo "$*"; }
hash() { sha256sum "$1" | awk '{print $1}'; }
size() { blockdev --getsize64 "$1"; }
part() {
 case "$1" in boot_a|boot_b|dtbo_a|dtbo_b) ;; *) fail '分区不在白名单';; esac
 printf '%s/%s\n' "$PARTDIR" "$1"
}
expect() { [ "$(hash "$1")" = "$2" ] || fail "读回 SHA256 不匹配：$(basename "$1")；不重启"; }
hex_sha() { [ ${#1} -eq 64 ] || return 1; case "$1" in *[!0-9a-f]*) return 1;; esac; }
cleanup() {
 if [ "$LOCKED" = 1 ]; then rm -f "$STATE/lock/pid" "$STATE/lock/boot"; rmdir "$STATE/lock" 2>/dev/null || true; LOCKED=0; fi
 if [ -n "$MOUNT_POINT" ]; then
  umount "$MOUNT_POINT" 2>/dev/null && rmdir "$MOUNT_POINT" 2>/dev/null || true
  MOUNT_POINT=
 fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
identify() {
 [ "$(id -u)" = 0 ] || fail '需要 root 权限'
 if [ -x /system/bin/getprop ] && [ -d /dev/block/by-name ]; then
  OS=android; PARTDIR=/dev/block/by-name
  product="$(getprop ro.product.device) $(getprop ro.product.vendor.device)"
  case "$product" in *PQ83A01*|*cerro*|*NX721J*) ;; *) fail '仅支持已核对的 Cerro / NX721J';; esac
  suffix=$(getprop ro.boot.slot_suffix)
  SERIAL=$(getprop ro.serialno)
 else
  OS=linux; PARTDIR=/dev/disk/by-partlabel
  [ -r /sys/firmware/devicetree/base/compatible ] || fail '不是支持的手机'
  tr '\000' '\n' < /sys/firmware/devicetree/base/compatible | grep -qx 'nubia,cerro' || fail '不是 Cerro'
  suffix=$(sed -n 's/.*androidboot.slot_suffix=\(_[ab]\)\([[:space:]].*\)\{0,1\}$/\1/p' /proc/cmdline)
  SERIAL=$(sed -n 's/.*androidboot.serialno=\([^[:space:]]*\).*/\1/p' /proc/cmdline)
 fi
 case "$suffix" in _a) SLOT=a; OTHER=b;; _b) SLOT=b; OTHER=a;; *) fail '无法确认活动槽，不写入';; esac
 case "$SERIAL" in ''|*[!A-Za-z0-9_.-]*) fail '设备标识无效';; esac
 for name in boot_a dtbo_a boot_b dtbo_b; do [ -b "$(part "$name")" ] || fail "缺少分区 $name"; done
 BOOT_SIZE=$(size "$(part boot_$SLOT)"); DTBO_SIZE=$(size "$(part dtbo_$SLOT)")
 [ "$BOOT_SIZE" = 100663296 ] || fail 'boot 不是已验证的 96MiB 布局'
 [ "$(size "$(part boot_$OTHER)")" = "$BOOT_SIZE" ] || fail '双槽 boot 长度不同'
 [ "$(size "$(part dtbo_$OTHER)")" = "$DTBO_SIZE" ] || fail '双槽 dtbo 长度不同'
 [ "$DTBO_SIZE" -ge 1048576 ] && [ "$DTBO_SIZE" -le 67108864 ] || fail 'DTBO 分区尺寸异常'
 ROOT_PART=$PARTDIR/cerro_linux
 [ -b "$ROOT_PART" ] || fail '需要现有独立 cerro_linux 分区；本应用不分区'
 magic=$(od -An -tx1 -j1080 -N2 "$ROOT_PART" | tr -d ' \n')
 [ "$magic" = 53ef ] || fail 'Linux 分区不是预期 ext4'
 ROOT_UUID=$(od -An -tx1 -j1128 -N16 "$ROOT_PART" | tr -d ' \n')
 [ ${#ROOT_UUID} -eq 32 ] || fail '无法读取 Linux 文件系统 UUID'
}
connect_state() {
 if [ "$OS" = android ]; then
  MOUNT_POINT=$(mktemp -d /data/local/tmp/cerro-switch.XXXXXX)
  mount -t ext4 -o nosuid,nodev "$ROOT_PART" "$MOUNT_POINT" || fail 'Linux 根分区无法挂载，尚未改写 boot/dtbo'
  # Existing Cerro installs bind/switch into debian-root inside the ext4
  # partition. Resolve that same live root before choosing shared state.
  if [ -d "$MOUNT_POINT/debian-root" ] && [ ! -L "$MOUNT_POINT/debian-root" ] &&
     [ -f "$MOUNT_POINT/debian-root/etc/debian_version" ] &&
     [ -f "$MOUNT_POINT/debian-root/usr/lib/systemd/systemd" ]; then
   LIVE_ROOT=$MOUNT_POINT/debian-root
  elif [ -f "$MOUNT_POINT/etc/debian_version" ] &&
       [ -f "$MOUNT_POINT/usr/lib/systemd/systemd" ]; then
   LIVE_ROOT=$MOUNT_POINT
  else
   fail '挂载分区中找不到已安装的 Debian 根目录，尚未改写 boot/dtbo'
  fi
  STATE=$LIVE_ROOT/var/lib/cerro-dualboot-device
 else
  # Verify this is the mounted Linux rootfs, not a different host or chroot.
  rootdev=$(awk '$2=="/" {print $1}' /proc/mounts | head -n1)
  [ "$(readlink -f "$rootdev")" = "$(readlink -f "$ROOT_PART")" ] || fail '当前根分区不是 cerro_linux'
  STATE=/var/lib/cerro-dualboot-device
 fi
 [ ! -L "$STATE" ] || fail '状态目录不能是符号链接'
 mkdir -p "$STATE"; chmod 700 "$STATE"
 if ! mkdir "$STATE/lock" 2>/dev/null; then
  current=$(cat /proc/sys/kernel/random/boot_id)
  old=$(cat "$STATE/lock/boot" 2>/dev/null || true)
  pid=$(cat "$STATE/lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) pid=0;; esac
  if [ -n "$old" ] && { [ "$old" != "$current" ] || { [ "$pid" -gt 1 ] && ! kill -0 "$pid" 2>/dev/null; }; }; then
   rm -f "$STATE/lock/pid" "$STATE/lock/boot"; rmdir "$STATE/lock" || fail '切换锁异常'
   mkdir "$STATE/lock" || fail '另一个切换进程正在运行'
  else fail '另一个切换进程正在运行'; fi
 fi
 LOCKED=1
 echo "$$" > "$STATE/lock/pid"; cat /proc/sys/kernel/random/boot_id > "$STATE/lock/boot"
}
field() {
 [ -f "$STATE/state" ] && [ ! -L "$STATE/state" ] || fail '没有机内互切清单；请先从 Android 应用切入，或导入电脑清单'
 [ "$(grep -c "^$1=" "$STATE/state")" = 1 ] || fail '切换清单字段异常'
 sed -n "s/^$1=//p" "$STATE/state"
}
load_state() {
 [ "$(field version)" = 1 ] || fail '状态格式不支持'
 [ "$(field serial)" = "$SERIAL" ] && [ "$(field slot)" = "$SLOT" ] && [ "$(field cache_slot)" = "$OTHER" ] || fail '设备或槽位已改变'
 [ "$(field root_uuid)" = "$ROOT_UUID" ] || fail 'Linux 文件系统已改变'
 [ "$(field boot_size)" = "$BOOT_SIZE" ] && [ "$(field dtbo_size)" = "$DTBO_SIZE" ] || fail '分区布局已改变'
 ANDROID_BOOT=$(field android_boot); ANDROID_DTBO=$(field android_dtbo); LINUX_BOOT=$(field linux_boot)
 hex_sha "$ANDROID_BOOT" && hex_sha "$ANDROID_DTBO" && hex_sha "$LINUX_BOOT" || fail '状态 SHA256 无效'
 RUN=$(field run)
 case "$RUN" in ''|*[!A-Za-z0-9_.-]*) fail '备份目录标签异常';; esac
}
write_state() {
 phase=$1
 temp=$STATE/state.new
 [ ! -L "$temp" ] || fail '状态文件异常'
 {
  echo version=1; echo "serial=$SERIAL"; echo "slot=$SLOT"; echo "cache_slot=$OTHER"
  echo "root_uuid=$ROOT_UUID"; echo "boot_size=$BOOT_SIZE"; echo "dtbo_size=$DTBO_SIZE"
  echo "android_boot=$ANDROID_BOOT"; echo "android_dtbo=$ANDROID_DTBO"; echo "linux_boot=$LINUX_BOOT"
  echo "run=$RUN"; echo "phase=$phase"
 } > "$temp"
 chmod 600 "$temp"; sync; mv "$temp" "$STATE/state"; sync
 log "步骤完成：$phase"
}
zero_hash() { head -c "$DTBO_SIZE" /dev/zero | sha256sum | awk '{print $1}'; }
linux_header() {
 [ "$(head -c8 "$1")" = 'ANDROID!' ] || fail '请选择 Linux boot.img，不是裸 Image 或压缩包'
 version=$(od -An -tu4 -j40 -N4 "$1" | tr -d ' \n')
 stub=$(od -An -tu4 -j16 -N4 "$1" | tr -d ' \n')
 [ "$version" = 2 ] && [ "$stub" = 127 ] || fail '镜像不符合 Cerro v2/stub127 打包格式'
 dd if="$1" bs=4096 count=1 2>/dev/null | grep -aq 'cerro_boot=' || fail '镜像缺少 Cerro Linux 标记'
}
android_source() {
 [ "$OS" = android ] || fail '只能从正在运行的 Android 建立 Android 备份'
 active=$(part boot_$SLOT)
 if dd if="$active" bs=4096 count=1 2>/dev/null | grep -aq 'cerro_boot='; then
  fail '活动 boot 已经是 Linux，不能覆盖 Android 缓存'
 fi
 [ "$(hash "$(part dtbo_$SLOT)")" != "$(zero_hash)" ] || fail '活动 DTBO 已清零，不能作为 Android 备份'
 if [ -f "$STATE/state" ]; then
  load_state
  case "$(field phase)" in android_ready) ;; *) fail '上次切换尚未恢复；先恢复 Android，不覆盖缓存';; esac
 fi
}
validate_image() {
 image=${1:-}
 case "$image" in /storage/emulated/0/linuxkernel/*.img|/data/media/0/linuxkernel/*.img) ;; *) fail '镜像必须在内部共享存储 linuxkernel 目录';; esac
 case "${image##*/}" in *'
'*) fail '文件名不能包含换行';; esac
 [ -f "$image" ] && [ ! -L "$image" ] || fail '找不到普通镜像文件'
 # No nested paths, traversal or symlink escape from the designated directory.
 parent=$(readlink -f "$(dirname "$image")")
 case "$parent" in /storage/emulated/0/linuxkernel|/data/media/0/linuxkernel|/mnt/user/0/emulated/0/linuxkernel|/mnt/runtime/*/emulated/0/linuxkernel) ;; *) fail '镜像目录解析不符';; esac
 [ "$(stat -c %s "$image")" = "$BOOT_SIZE" ] || fail '镜像必须完整填充为 96MiB'
 linux_header "$image"
 IMAGE=$image; IMAGE_SHA=$(hash "$image")
}
backup_all() {
 label=$1
 RUN=$(date -u +%Y%m%dT%H%M%SZ)-slot_$SLOT-$label-$$
 dir=$STATE/backups/$RUN
 mkdir -p "$STATE/backups"; mkdir "$dir" || fail '无法创建独立备份'
 printf '现场=%s; active=slot_%s; inactive=slot_%s; rootfs=%s\n' "$label" "$SLOT" "$OTHER" "$ROOT_UUID" > "$dir/LABEL.txt"
 for s in a b; do
  for k in boot dtbo; do
   source=$(part ${k}_$s); target=$dir/${k}_slot_$s.img
   wanted=$(hash "$source"); bytes=$(size "$source")
   dd if="$source" of="$target" bs=1048576 conv=fsync 2>/dev/null || fail '备份读写失败'
   [ "$(stat -c %s "$target")" = "$bytes" ] || fail '备份长度不完整'
   expect "$target" "$wanted"; expect "$source" "$wanted"
   echo "$wanted  ${k}_slot_$s.img" >> "$dir/SHA256SUMS"
   log "原件备份已校验：${k}_slot_$s"
  done
 done
 sync
}
verify_backup_scene() {
 dir=$STATE/backups/$RUN
 while read -r wanted name; do
  case "$name" in boot_slot_a.img) p=boot_a;; boot_slot_b.img) p=boot_b;; dtbo_slot_a.img) p=dtbo_a;; dtbo_slot_b.img) p=dtbo_b;; *) fail '备份清单名称异常';; esac
  expect "$(part "$p")" "$wanted"
 done < "$dir/SHA256SUMS"
}
copy_part() {
 dd if="$1" of="$2" bs=1048576 conv=fsync 2>/dev/null || fail '写入失败；不重启'
 expect "$2" "$3"
}
verify_cache() { expect "$(part boot_$OTHER)" "$ANDROID_BOOT"; expect "$(part dtbo_$OTHER)" "$ANDROID_DTBO"; }
plan_linux() {
 android_source; validate_image "$2"
 log "运行系统：Android；活动槽：$SLOT；Android 缓存槽：$OTHER"
 log "镜像：${IMAGE##*/}"
 log "SHA256=$IMAGE_SHA"
 log "先完整备份两槽 boot/dtbo；将 Android 两文件缓存至 $OTHER，清空 $SLOT 的 DTBO，写 Linux boot 并重启。活动槽不变。"
}
switch_linux() {
 android_source; validate_image "$2"; expected=${3:-}; hex_sha "$expected" || fail '请先预览并确认镜像 SHA'
 [ "$IMAGE_SHA" = "$expected" ] || fail '镜像自预览后已改变'
 ANDROID_BOOT=$(hash "$(part boot_$SLOT)"); ANDROID_DTBO=$(hash "$(part dtbo_$SLOT)"); LINUX_BOOT=$IMAGE_SHA
 backup_all Android
 staged=$STATE/backups/$RUN/linux_boot_slot_$SLOT.img
 cp "$IMAGE" "$staged" || fail '镜像暂存失败'; chmod 600 "$staged"
 [ "$(stat -c %s "$staged")" = "$BOOT_SIZE" ] || fail '暂存镜像不完整'
 expect "$staged" "$LINUX_BOOT"; linux_header "$staged"
 expect "$(part boot_$SLOT)" "$ANDROID_BOOT"; expect "$(part dtbo_$SLOT)" "$ANDROID_DTBO"
 verify_backup_scene
 write_state prepared
 copy_part "$(part boot_$SLOT)" "$(part boot_$OTHER)" "$ANDROID_BOOT"
 copy_part "$(part dtbo_$SLOT)" "$(part dtbo_$OTHER)" "$ANDROID_DTBO"
 verify_cache; write_state android_cache_verified
 head -c "$DTBO_SIZE" /dev/zero | dd of="$(part dtbo_$SLOT)" bs=1048576 conv=fsync 2>/dev/null
 expect "$(part dtbo_$SLOT)" "$(zero_hash)"; write_state active_dtbo_zero
 copy_part "$staged" "$(part boot_$SLOT)" "$LINUX_BOOT"
 verify_cache; expect "$(part dtbo_$SLOT)" "$(zero_hash)"; write_state linux_ready
 finish_reboot
}
plan_android() {
 load_state
 if [ "$(hash "$(part boot_$SLOT)")" = "$ANDROID_BOOT" ] && [ "$(hash "$(part dtbo_$SLOT)")" = "$ANDROID_DTBO" ]; then
  log "活动槽 $SLOT 已是清单中的 Android；不重复改写。"
 else verify_cache; log "将已校验的槽 $OTHER Android boot/dtbo 恢复到原活动槽 $SLOT，活动槽不变。"; fi
}
switch_android() {
 load_state
 if [ "$(hash "$(part boot_$SLOT)")" = "$ANDROID_BOOT" ] && [ "$(hash "$(part dtbo_$SLOT)")" = "$ANDROID_DTBO" ]; then
  write_state android_ready
  if [ "$OS" = android ]; then log 'Android 已完整恢复；没有写分区。'; return; fi
 else
  verify_cache
  # Preserve the entire pre-restore scene in a second independently labelled run.
  oldrun=$RUN; backup_all Linux-pre-restore; RUN=$oldrun
  verify_cache
  write_state restoring_android
  copy_part "$(part dtbo_$OTHER)" "$(part dtbo_$SLOT)" "$ANDROID_DTBO"
  copy_part "$(part boot_$OTHER)" "$(part boot_$SLOT)" "$ANDROID_BOOT"
  verify_cache; write_state android_ready
 fi
 finish_reboot
}
finish_reboot() {
 sync
 log '全部读回校验通过，准备重启。'
 if [ "$LOCKED" = 1 ]; then rm -f "$STATE/lock/pid" "$STATE/lock/boot"; rmdir "$STATE/lock"; LOCKED=0; fi
 if [ -n "$MOUNT_POINT" ]; then
  umount "$MOUNT_POINT" || fail '分区写入已完成，但状态分区卸载失败；请检查后手动重启'
  rmdir "$MOUNT_POINT"; MOUNT_POINT=
 fi
 if [ "$OS" = android ]; then reboot || fail '写入完成但重启失败，请手动重启';
 else systemctl reboot || fail '写入完成但重启失败，请手动重启'; fi
}
identify
case "$ACTION" in
 images)
  [ "$OS" = android ] || fail '镜像列表只用于 Android'
  for image in /data/media/0/linuxkernel/*.img; do
   [ -f "$image" ] && [ ! -L "$image" ] || continue
   name=${image##*/}; case "$name" in *'
'*) continue;; esac
   printf '%s\n' "$name"
  done
  exit 0;;
 status|plan-linux|switch-linux|plan-android|switch-android|import-host) connect_state;;
 *) fail '未知操作';;
esac
case "$ACTION" in
 status)
  log "系统=$OS 活动槽=$SLOT 缓存槽=$OTHER"
  if [ -f "$STATE/state" ]; then load_state; log "已保存阶段=$(field phase)"; else log '尚未建立机内互切清单'; fi;;
 plan-linux) plan_linux "$@";;
 switch-linux) switch_linux "$@";;
 import-host)
  [ "$OS" = linux ] || fail '电脑清单仅在 Linux 端导入'
  [ ! -f "$STATE/state" ] || fail '已有机内清单，拒绝覆盖'
  here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  python3 "$here/import-host-state.py" "$2" "$STATE" "$SLOT" "$OTHER" "$SERIAL" "$ROOT_UUID" "$PARTDIR" "$BOOT_SIZE" "$DTBO_SIZE";;
 plan-android) plan_android;;
 switch-android) switch_android;;
esac
