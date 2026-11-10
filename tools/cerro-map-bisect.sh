#!/usr/bin/env bash
# Cerro (path A): automate CERRO_MAP_MEM_STEP build → pack → flash → USB classify.
#
# 判定只靠 sticky fastboot 时机（CERRO_PROBE_SIGNAL=0 = PSCI reset）：
#   PASS: USB 先静默（多轮自动重启），之后 sticky fastboot、不再开机
#   FAIL: 很快 sticky fastboot（几乎没循环 / 像一开就进 fb）
#   DUMP: 19d2:0112
#   hang: 久等仍无 sticky fb
#
# SKIP_UNLOCK=1（你帮忙跳过解锁提示）时：
#   不算解锁等待；PASS_MIN ≈ 2×(开机到探针 + 探针 3s)
#   你跳过时脚本不「计解锁时长」，只看 fb 早晚。
#
# 无人跳过时：UNLOCK_WAIT 计入 CYCLE（默认 8s）。
#
# Usage:
#   SKIP_UNLOCK=1 ./tools/cerro-map-bisect.sh 2723 2724
#   ./tools/cerro-map-bisect.sh --dry-run 268
#   BANK_SIZE=0x20000000 SKIP_UNLOCK=1 ./tools/cerro-map-bisect.sh 3
#   Encoded bank@step3: 30000+MiB → e.g. 30256=256MiB, 39600=9600MiB (0x260000000)
#
set -euo pipefail

ROOT=/mnt/data/LOA_Nubia_Z60U
LINUX="$ROOT/build/linux"
MMU="$LINUX/arch/arm64/mm/mmu.c"
SETUP="$LINUX/arch/arm64/kernel/setup.c"
WORKDIR="$ROOT/build/boot_repack"
OUT_BOOT="$WORKDIR/boot-v2-builtin-dtb.img"
IMG="$LINUX/arch/arm64/boot/Image"
DTB="$LINUX/arch/arm64/boot/dts/qcom/sm8650-nubia-cerro.dtb"
FLASH="$ROOT/tools/edl-tools/flash-boot-any.sh"
LOGDIR="$ROOT/notes/bisect-logs"
LOG="$LOGDIR/map-bisect.tsv"
RUNLOG="$LOGDIR/map-bisect-$(date +%Y%m%d-%H%M%S).log"

BOOT_TO_PROBE_S=${BOOT_TO_PROBE_S:-3}
PROBE_DELAY_S=${PROBE_DELAY_S:-3}
MIN_PASS_CYCLES=${MIN_PASS_CYCLES:-2}

if [[ "${SKIP_UNLOCK:-0}" == "1" ]]; then
  # 你跳过解锁：时长不计入；只靠 fastboot 早晚
  UNLOCK_WAIT_S=0
else
  UNLOCK_WAIT_S=${UNLOCK_WAIT_S:-8}
fi

CYCLE_S=$((UNLOCK_WAIT_S + BOOT_TO_PROBE_S + PROBE_DELAY_S))
_DEFAULT_PASS_MIN=$((MIN_PASS_CYCLES * CYCLE_S))
# 至少盖住「两轮探针」：避免 SKIP_UNLOCK 时 PASS_MIN 过小
if (( _DEFAULT_PASS_MIN < 2 * (BOOT_TO_PROBE_S + PROBE_DELAY_S) )); then
  _DEFAULT_PASS_MIN=$((2 * (BOOT_TO_PROBE_S + PROBE_DELAY_S)))
fi
PASS_MIN_S=${PASS_MIN_S:-$_DEFAULT_PASS_MIN}
if (( PASS_MIN_S < _DEFAULT_PASS_MIN )); then
  PASS_MIN_S=$_DEFAULT_PASS_MIN
fi

# 主窗 + 延长窗：要等到 ABL 多轮后 sticky fb（参考无人跳过时 ~80s+）
OBSERVE_S=${OBSERVE_S:-$((PASS_MIN_S + CYCLE_S))}
if (( OBSERVE_S < PASS_MIN_S + 5 )); then
  OBSERVE_S=$((PASS_MIN_S + CYCLE_S + 5))
fi
# 延长默认盖住约 8 轮短循环或 ~70s（取较大）
_DEFAULT_EXTEND=$((8 * CYCLE_S))
if (( _DEFAULT_EXTEND < 70 )); then
  _DEFAULT_EXTEND=70
fi
QUIET_EXTEND_S=${QUIET_EXTEND_S:-$_DEFAULT_EXTEND}
JOBS=${JOBS:-$(nproc)}

DRY_RUN=0
NO_BUILD=0
STEPS=()

usage() {
  sed -n '2,20p' "$0" | sed 's/^# //;s/^#//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    --step) STEPS+=("$2"); shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --observe) OBSERVE_S="$2"; shift 2 ;;
    --) shift; STEPS+=("$@"); break ;;
    -*) echo "unknown: $1"; exit 2 ;;
    *) STEPS+=("$1"); shift ;;
  esac
done

# Default queue: baseline + current frontier (edit freely)
if [[ ${#STEPS[@]} -eq 0 ]]; then
  STEPS=(0 264 268 269)
fi

mkdir -p "$LOGDIR"
exec > >(stdbuf -oL -eL tee -a "$RUNLOG") 2>&1
echo "==== cerro-map-bisect $(date) pid=$$ ===="
echo "steps: ${STEPS[*]}"
echo "judge: sticky fastboot early(<PASS_MIN) = FAIL; late(>=PASS_MIN after quiet) = PASS"
echo "timing: SKIP_UNLOCK=${SKIP_UNLOCK:-0} UNLOCK_WAIT=${UNLOCK_WAIT_S}s CYCLE=${CYCLE_S}s PASS_MIN=${PASS_MIN_S}s OBSERVE=${OBSERVE_S}s EXTEND=${QUIET_EXTEND_S}s"
if [[ "${SKIP_UNLOCK:-0}" == "1" ]]; then
  echo "NOTE: 你跳过解锁时不算解锁时长；请在橙屏时跳过，脚本只看 fastboot 早晚"
else
  echo "NOTE: 无人跳过时 UNLOCK_WAIT 计入 PASS_MIN"
fi
echo "log: $RUNLOG"
echo "tsv: $LOG"

if [[ ! -f "$LOG" ]]; then
  printf 'timestamp\tstep\toutcome\tdetail\tboot_img\n' >"$LOG"
fi

# shellcheck source=lib/cerro-usb-detect.sh
source "$ROOT/tools/lib/cerro-usb-detect.sh"

beep_msg() {
  echo ""
  echo "******** $* ********"
  echo ""
  printf '\a' 2>/dev/null || true
}

wait_flashable() {
  local why="$1"
  local mode rc
  mode=$(cerro_detect_stable 2 0.3)
  if [[ "$mode" == fastboot_hint || "$mode" == fastboot_noperm ]]; then
    sudo chmod -R a+rw /dev/bus/usb 2>/dev/null || true
    mode=$(cerro_detect_stable 2 0.3)
  fi
  if cerro_is_flashable "$mode"; then
    echo "already flashable: $mode"
    return 0
  fi
  if [[ "$mode" == dump ]]; then
    beep_msg "MemoryDump — 强制关机后音量+和−同时按住进 9008"
    echo "DUMP_WHILE_WAITING"
    return 2
  fi
  beep_msg "$why — 请进 fastboot 或 9008"
  set +e
  cerro_wait_mode "edl,fastboot" 600
  rc=$?
  set -e
  return "$rc"
}

set_bank_size() {
  local hex="$1"
  hex="${hex%ULL}"
  [[ "$hex" == 0x* || "$hex" == 0X* ]] || hex="0x${hex}"
  if ! grep -qE '#define CERRO_FALLBACK_MEM_SIZE' "$SETUP"; then
    echo "CERRO_FALLBACK_MEM_SIZE not found in $SETUP"
    exit 1
  fi
  if ! grep -qE '#define CERRO_SAFE_MAP_SIZE' "$MMU"; then
    echo "CERRO_SAFE_MAP_SIZE not found in $MMU"
    exit 1
  fi
  sed -i -E "s/(#define CERRO_FALLBACK_MEM_SIZE[[:space:]]+)0x[0-9A-Fa-f]+ULL/\1${hex}ULL/" "$SETUP"
  sed -i -E "s/(#define CERRO_SAFE_MAP_SIZE[[:space:]]+)0x[0-9A-Fa-f]+ULL/\1${hex}ULL/" "$MMU"
  echo "set bank FALLBACK=SAFE_MAP=${hex} (LOW_ALLOC unchanged)"
}

set_step() {
  local step="$1"
  local map_step="$step"
  if ! grep -q '#define CERRO_MAP_MEM_STEP' "$MMU"; then
    echo "CERRO_MAP_MEM_STEP not found in $MMU"
    exit 1
  fi
  # 30000+MiB → MAP_MEM_STEP=3 + bank size MiB (pt alloc window stays low 256MiB)
  if (( step >= 30000 && step < 40000 )); then
    local mib=$((step - 30000))
    local hex
    hex=$(printf '0x%x' $((mib * 1024 * 1024)))
    set_bank_size "$hex"
    map_step=3
  elif [[ -n "${BANK_SIZE:-}" ]]; then
    set_bank_size "$BANK_SIZE"
  fi
  sed -i -E "s/#define CERRO_MAP_MEM_STEP [0-9]+/#define CERRO_MAP_MEM_STEP ${map_step}/" "$MMU"
  if grep -q '#define CERRO_PROBE_SIGNAL' "$SETUP"; then
    sed -i -E 's/#define CERRO_PROBE_SIGNAL [0-9]+/#define CERRO_PROBE_SIGNAL 0/' "$SETUP"
  fi
  if [[ -n "${PROBE_STAGE:-}" ]] && grep -q '#define CERRO_PROBE_STAGE' "$SETUP"; then
    sed -i -E "s/#define CERRO_PROBE_STAGE [0-9]+/#define CERRO_PROBE_STAGE ${PROBE_STAGE}/" "$SETUP"
    echo "set CERRO_PROBE_STAGE=${PROBE_STAGE}"
  fi
  if [[ -n "${IDMAP_STEP:-}" ]]; then
    if grep -qE '#define CERRO_IDMAP_STEP' "$MMU"; then
      sed -i -E "s/#define CERRO_IDMAP_STEP [0-9]+/#define CERRO_IDMAP_STEP ${IDMAP_STEP}/" "$MMU"
    else
      # insert override before the ifndef default in create_idmap path
      sed -i -E "s/#ifndef CERRO_IDMAP_STEP/#define CERRO_IDMAP_STEP ${IDMAP_STEP}\n#ifndef CERRO_IDMAP_STEP/" "$MMU"
    fi
    echo "set CERRO_IDMAP_STEP=${IDMAP_STEP}"
  fi
  if [[ -n "${SKIP_UNFLATTEN:-}" ]]; then
    if grep -qE '#define CERRO_SKIP_UNFLATTEN' "$SETUP"; then
      sed -i -E "s/#define CERRO_SKIP_UNFLATTEN [0-9]+/#define CERRO_SKIP_UNFLATTEN ${SKIP_UNFLATTEN}/" "$SETUP"
    fi
    echo "set CERRO_SKIP_UNFLATTEN=${SKIP_UNFLATTEN}"
  fi
  local got
  got=$(grep -E '#define CERRO_MAP_MEM_STEP' "$MMU" | head -1)
  echo "set $got (PROBE_SIGNAL=0 PSCI) record_step=$step"
}

build_image() {
  echo "==== build Image (jobs=$JOBS) ===="
  make -C "$LINUX" ARCH=arm64 LLVM=1 -j"$JOBS" Image
  test -f "$IMG"
  local ok=0 i
  for i in 1 2 3 4 5; do
    if grep -qE 'Using built-in cerro DTB|built-in cerro DTB|cerro: probe stage' \
         < <(strings "$IMG"); then
      ok=1
      break
    fi
    sleep 1
  done
  if [[ "$ok" != 1 ]]; then
    echo "ERROR: Image missing cerro markers (builtin DTB / probe)"
    strings "$IMG" | grep -i cerro | head -20 || true
    exit 1
  fi
  ls -lh "$IMG"
}

pack_boot() {
  echo "==== pack boot-v2-builtin-dtb.img ===="
  mkdir -p "$WORKDIR/out"
  test -f "$WORKDIR/out/ramdisk"
  local hdr_dtb="$WORKDIR/out/dtb-id.dtb"
  if [[ ! -f "$hdr_dtb" ]]; then
    hdr_dtb="$WORKDIR/out/dtb"
  fi
  if [[ -f "$DTB" ]]; then
    cp -f "$DTB" "$WORKDIR/out/dtb"
  fi
  test -f "$hdr_dtb"

  cp -f "$IMG" "$WORKDIR/Image.raw"
  python3 - "$WORKDIR" "$hdr_dtb" <<'PY'
import struct, sys
workdir, hdr_dtb = sys.argv[1], sys.argv[2]
img = open(f'{workdir}/Image.raw', 'rb').read()
dtb = open(hdr_dtb, 'rb').read()
image_size = struct.unpack_from('<Q', img, 0x10)[0]
if image_size < len(img):
    raise SystemExit(f'bad image_size {image_size} < {len(img)}')
padded = img + b'\x00' * (image_size - len(img)) + dtb
open(f'{workdir}/Image-dtb-bsspad.raw', 'wb').write(padded)
print('kernel blob', len(padded), 'hdr_dtb', hdr_dtb)
PY

  local cmdline='ignore_loglevel pd_ignore_unused clk_ignore_unused console=ttyMSM0,115200n8 earlycon=qcom_geni,0x0089c000 pmos_boot_uuid=0ad60230-638c-49c0-9c95-ab8938f81eaf pmos_root_uuid=ab3a863b-512a-447e-a35c-e681ce0ae61b pmos_rootfsopts=defaults'
  mkbootimg --header_version 2 --pagesize 4096 \
    --base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
    --tags_offset 0x100 --dtb_offset 0x01f00000 \
    --kernel "$WORKDIR/Image-dtb-bsspad.raw" \
    --ramdisk "$WORKDIR/out/ramdisk" \
    --dtb "$hdr_dtb" \
    --cmdline "$cmdline" \
    --os_version 16.0.0 --os_patch_level 2026-07 \
    -o "$OUT_BOOT"
  ls -lh "$OUT_BOOT"
}

flash_boot() {
  echo "==== flash ===="
  wait_flashable "准备刷入 step 镜像"
  "$FLASH" "$OUT_BOOT"
  echo "flash returned $(date)"
}

# Classify after flash. Uses Uotan-style multi-channel + debounce.
# Globals: OUTCOME DETAIL
observe() {
  local t0="" first_fb_at="" fb_hits=0 dump_hits=0
  local i mode
  OUTCOME=unknown
  DETAIL=""

  echo "==== observe ${OBSERVE_S}s (Uotan-style detect + debounce) ===="
  cerro_detect_detail | sed 's/^/  pre: /'

  # Wait until we leave flashable mode (hand-off), up to 25s
  for i in $(seq 1 50); do
    mode=$(cerro_detect_stable 2 0.3)
    if [[ "$mode" == none || "$mode" == dump ]]; then
      t0=$(date +%s.%N)
      echo "boot window start mode=$mode t0=$t0"
      break
    fi
    if [[ "$mode" == fastboot || "$mode" == edl ]] && (( i >= 20 )); then
      OUTCOME=early_fastboot
      DETAIL="sticky_${mode}_never_left_flash"
      echo "outcome=$OUTCOME $DETAIL"
      return 0
    fi
    sleep 0.4
  done
  if [[ -z "$t0" ]]; then
    t0=$(date +%s.%N)
    echo "WARN: never saw leave-flash; t0=$t0 mode=$(cerro_detect_raw)"
  fi

  local loops=$((OBSERVE_S * 2))
  local none_streak=0 saw_any_usb=0
  # Optional: count USB add/remove (PSCI reboot may tick the hub even if lsusb stays empty)
  local udev_log="$LOGDIR/udev-observe-$$.log"
  rm -f "$udev_log"
  ( udevadm monitor --udev --subsystem-match=usb 2>/dev/null | stdbuf -oL grep -E 'add|remove' >>"$udev_log" ) &
  local udev_pid=$!

  for i in $(seq 1 "$loops"); do
    mode=$(cerro_detect_raw)
    local now elapsed
    now=$(date +%s.%N)
    elapsed=$(python3 -c "print(round(float('$now')-float('$t0'), 3))")

    case "$mode" in
      dump)
        dump_hits=$((dump_hits + 1))
        fb_hits=0
        none_streak=0
        if (( dump_hits >= 2 )); then
          kill "$udev_pid" 2>/dev/null || true
          OUTCOME=dump
          DETAIL="MemoryDump@${elapsed}s"
          echo "[$elapsed] DUMP (debounced)"
          echo "outcome=$OUTCOME $DETAIL"
          return 0
        fi
        ;;
      fastboot)
        dump_hits=0
        none_streak=0
        saw_any_usb=1
        if [[ -z "$first_fb_at" ]]; then
          first_fb_at=$elapsed
          echo "[$elapsed] fastboot devices first seen"
        fi
        fb_hits=$((fb_hits + 1))
        if (( fb_hits >= 2 )); then
          kill "$udev_pid" 2>/dev/null || true
          # 很快 sticky fb = 直接进 fb / 几乎无 PSCI 循环；晚出现 = 多轮重启后 ABL 放弃
          if python3 -c "import sys; sys.exit(0 if float('$first_fb_at') < float('$PASS_MIN_S') else 1)"; then
            OUTCOME=early_fastboot
            DETAIL="early_fastboot@${first_fb_at}s_PASS_MIN=${PASS_MIN_S}_CYCLE=${CYCLE_S}"
          else
            OUTCOME=pass
            DETAIL="late_fastboot@${first_fb_at}s_after_ge_${MIN_PASS_CYCLES}cycles_PASS_MIN=${PASS_MIN_S}"
          fi
          echo "outcome=$OUTCOME $DETAIL"
          return 0
        fi
        ;;
      edl)
        dump_hits=0
        fb_hits=0
        none_streak=0
        saw_any_usb=1
        echo "[$elapsed] unexpected EDL"
        ;;
      none)
        dump_hits=0
        fb_hits=0
        none_streak=$((none_streak + 1))
        ;;
      *)
        dump_hits=0
        fb_hits=0
        none_streak=0
        saw_any_usb=1
        ;;
    esac
    if (( i % 4 == 0 )); then
      echo "[$elapsed] mode=$mode"
    fi
    sleep 0.5
  done

  kill "$udev_pid" 2>/dev/null || true
  wait "$udev_pid" 2>/dev/null || true
  local udev_n=0
  if [[ -f "$udev_log" ]]; then
    udev_n=$(wc -l <"$udev_log" | tr -d ' ')
  fi
  echo "observe done: none_streak=$none_streak udev_events=$udev_n first_fb=${first_fb_at:-none}"

  # Still quiet: keep watching for late sticky fb (PASS) or dump.
  # 默认不再把「一直静默」直接当 PASS —— 要等到 sticky fastboot（多轮后 ABL 放弃）。
  local extra=${QUIET_EXTEND_S}
  echo "==== quiet so far; extend ${extra}s (wait late sticky fb ≥ PASS_MIN=${PASS_MIN_S}s) ===="
  local extend_deadline=$((SECONDS + extra))
  fb_hits=0
  dump_hits=0
  # keep first_fb_at empty for extend-only appearance
  local ext_first_fb=""
  while (( SECONDS < extend_deadline )); do
    mode=$(cerro_detect_raw)
    now=$(date +%s.%N)
    elapsed=$(python3 -c "print(round(float('$now')-float('$t0'), 3))")
    case "$mode" in
      dump)
        dump_hits=$((dump_hits + 1))
        if (( dump_hits >= 2 )); then
          OUTCOME=dump; DETAIL="MemoryDump@${elapsed}s(extend)"
          echo "outcome=$OUTCOME $DETAIL"; return 0
        fi
        ;;
      fastboot)
        if [[ -z "$ext_first_fb" ]]; then
          ext_first_fb=$elapsed
          echo "[$elapsed] fastboot during extend"
        fi
        fb_hits=$((fb_hits + 1))
        if (( fb_hits >= 2 )); then
          if python3 -c "import sys; sys.exit(0 if float('$ext_first_fb') < float('$PASS_MIN_S') else 1)"; then
            OUTCOME=early_fastboot
            DETAIL="early_fastboot@${ext_first_fb}s(extend)_PASS_MIN=${PASS_MIN_S}"
          else
            OUTCOME=pass
            DETAIL="late_fastboot@${ext_first_fb}s(extend)_PASS_MIN=${PASS_MIN_S}_CYCLE=${CYCLE_S}"
          fi
          echo "outcome=$OUTCOME $DETAIL"
          return 0
        fi
        ;;
      *)
        fb_hits=0
        dump_hits=0
        ;;
    esac
    sleep 0.5
  done

  # Still no sticky fb: ambiguous (仍在循环 / 真挂死). Default hang — 勿 quiet 当 PASS.
  local policy=${QUIET_POLICY:-hang}
  case "$policy" in
    ask|ASK)
      ;;
    pass|PASS)
      OUTCOME=pass
      DETAIL="quiet_forced_pass_${OBSERVE_S}+${extra}s_udev${udev_n}"
      echo "outcome=$OUTCOME $DETAIL (QUIET_POLICY=pass)"; return 0
      ;;
    *)
      OUTCOME=hang
      DETAIL="quiet_${OBSERVE_S}+${extra}s_no_sticky_fb_PASS_MIN=${PASS_MIN_S}"
      echo "outcome=$OUTCOME $DETAIL"
      return 0
      ;;
  esac

  # policy=ask fallback (rare)
  local askf="$LOGDIR/quiet-ask.txt"
  local ansf="$LOGDIR/quiet-ans.txt"
  rm -f "$ansf"
  cat >"$askf" <<EOF
USB quiet — ambiguous hang vs still looping. Prefer waiting longer or QUIET_POLICY=hang.
  echo p > $ansf / echo h > $ansf
EOF
  beep_msg "仍需确认 quiet（无人值守勿按解锁跳过；默认应等 sticky fb）"
  local ans="" deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if [[ -f "$ansf" ]]; then
      ans=$(tr -d '[:space:]' <"$ansf" | head -c 1)
      rm -f "$ansf" "$askf"
      break
    fi
    # Late sticky fastboot while asking
    mode=$(cerro_detect_raw)
    now=$(date +%s.%N)
    elapsed=$(python3 -c "print(round(float('$now')-float('$t0'), 3))")
    if [[ "$mode" == fastboot ]]; then
      if python3 -c "import sys; sys.exit(0 if float('$elapsed') < float('$PASS_MIN_S') else 1)"; then
        OUTCOME=early_fastboot; DETAIL="fastboot_while_asking@${elapsed}s_early"
      else
        OUTCOME=pass; DETAIL="late_fastboot_while_asking@${elapsed}s"
      fi
      echo "outcome=$OUTCOME $DETAIL"; return 0
    fi
    if [[ "$mode" == dump ]]; then
      OUTCOME=dump; DETAIL="dump_while_asking"
      echo "outcome=$OUTCOME $DETAIL"; return 0
    fi
    sleep 1
  done
  ans=${ans:-h}
  case "$ans" in
    p|P) OUTCOME=pass; DETAIL="quiet_user_confirm_pass" ;;
    d|D) OUTCOME=dump; DETAIL="quiet_user_dump" ;;
    f|F) OUTCOME=early_fastboot; DETAIL="quiet_user_fastboot" ;;
    *)   OUTCOME=hang; DETAIL="quiet_user_hang_or_timeout" ;;
  esac
  echo "outcome=$OUTCOME $DETAIL"
}

record() {
  local step="$1"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" "$step" "$OUTCOME" "$DETAIL" "$OUT_BOOT" >>"$LOG"
  echo "recorded → $LOG"
}

run_one() {
  local step="$1"
  echo ""
  echo "################ STEP $step ################"
  set_step "$step"

  if [[ "$DRY_RUN" == 1 ]]; then
    echo "dry-run: skip build/flash"
    return 0
  fi

  if [[ "$NO_BUILD" != 1 ]]; then
    build_image
  else
    echo "skip build (--no-build)"
  fi
  pack_boot
  flash_boot
  # Give ABL a moment after reset
  sleep 2
  observe
  record "$step"

  case "$OUTCOME" in
    pass)
      echo "STEP $step PASS — 等可刷模式；若随后 Dump 会撤销 PASS"
      set +e
      wait_flashable "PASS 后刷下一档"
      local wrc=$?
      set -e
      if (( wrc == 2 )); then
        OUTCOME=dump
        DETAIL="dump_after_false_quiet_pass"
        record "$step"
        echo "REVOKED step $step → dump (quiet auto-pass was wrong)"
        wait_flashable "dump 后请手动进 9008" || true
      fi
      ;;
    early_fastboot)
      echo "STEP $step FAIL (early fastboot / panic before probe)"
      ;;
    dump)
      beep_msg "STEP $step DUMP — 下一轮前需手动进 9008"
      wait_flashable "dump 后请手动进 9008" || true
      ;;
    hang)
      beep_msg "STEP $step HANG — 请手动强制关机后音量+/−进 9008（崩hang不会自动进）"
      wait_flashable "hang 后继续" || true
      ;;
    *)
      beep_msg "STEP $step UNKNOWN=$OUTCOME — 请确认模式"
      wait_flashable "unknown 后继续" || true
      ;;
  esac
}

for s in "${STEPS[@]}"; do
  run_one "$s"
done

echo ""
echo "==== ALL STEPS DONE $(date) ===="
echo "Results:"
column -t -s $'\t' "$LOG" 2>/dev/null || cat "$LOG"
echo "run log: $RUNLOG"
