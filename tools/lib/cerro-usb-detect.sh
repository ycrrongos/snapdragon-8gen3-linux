#!/usr/bin/env bash
# Cerro USB/mode detection — patterned after UotanToolboxNT:
#   - FastbootTransport: primary = `fastboot devices` (not raw lsusb VID alone)
#   - EdlTransport/COMDevices: Linux lsusb line containing `:9008`
#   - DeviceManager: debounce — require N consecutive identical readings
# Extra (cerro-specific): ZTE MemoryDump 19d2:0112
#
# Usage:
#   source this file, then:
#     cerro_detect_raw          → prints one of: fastboot|edl|dump|adb|none|other
#     cerro_detect_stable 2 0.5 → debounced mode (default 2 hits, 0.5s apart)
#     cerro_wait_mode edl,fastboot 300   → wait until mode in list (seconds)
#
# shellcheck shell=bash

cerro_detect_raw() {
  local lsusb_out fb_out adb_out
  lsusb_out=$(lsusb 2>/dev/null || true)

  # --- EDL 9008 (Uotan: Lines[i].Contains(":9008")) ---
  if echo "$lsusb_out" | grep -qiE '05c6:9008|:9008'; then
    echo edl
    return 0
  fi

  # --- ZTE MemoryDump (cerro bring-up; not in Uotan) ---
  if echo "$lsusb_out" | grep -qiE '19d2:0112'; then
    echo dump
    return 0
  fi

  # --- Fastboot: trust `fastboot devices` first (Uotan FastbootTransport) ---
  fb_out=$(fastboot devices 2>/dev/null || true)
  if echo "$fb_out" | grep -qE '[[:alnum:]]+[[:space:]]+fastboot'; then
    echo fastboot
    return 0
  fi
  # Linux permission trap (Uotan warns on "no permissions")
  if echo "$fb_out" | grep -qi 'no permissions'; then
    echo fastboot_noperm
    return 0
  fi
  # Secondary hint only: lsusb says fastboot gadget but fastboot CLI empty
  if echo "$lsusb_out" | grep -qiE '18d1:d00d|\(fastboot\)'; then
    echo fastboot_hint
    return 0
  fi

  # --- ADB: only if it looks like *this* phone (avoid host emulators / other devices) ---
  # Select explicitly, or recognize Cerro product metadata; no per-user serial.
  local want_serial=${CERRO_SERIAL:-}
  adb_out=$(adb devices -l 2>/dev/null || true)
  if awk -v serial="$want_serial" '
    $2 ~ /^(device|recovery|sideload)$/ {
      if ((serial != "" && $1 == serial) ||
          (serial == "" && $0 ~ /device:PQ83A01([[:space:]]|$)/)) found=1
    }
    END {exit !found}' <<< "$adb_out"; then
    echo adb
    return 0
  fi
  # Do NOT treat unrelated `adb devices` entries as cerro state.
  # Other Qualcomm diagnostic modes Uotan knows (900E/901D/9091)
  if echo "$lsusb_out" | grep -qiE ':900e|:901d|:9091'; then
    echo qcom_diag
    return 0
  fi

  if [[ -n "$lsusb_out" ]] && echo "$lsusb_out" | grep -qiE '05c6:|18d1:|19d2:'; then
    echo other
    return 0
  fi

  echo none
}

# Require $1 consecutive identical readings, sleep $2 between polls.
cerro_detect_stable() {
  local need=${1:-2}
  local gap=${2:-0.5}
  local last="" cur="" hits=0 i
  for i in $(seq 1 $((need * 8))); do
    cur=$(cerro_detect_raw)
    if [[ "$cur" == "$last" ]]; then
      hits=$((hits + 1))
    else
      last=$cur
      hits=1
    fi
    if (( hits >= need )); then
      echo "$cur"
      return 0
    fi
    sleep "$gap"
  done
  echo "${last:-none}"
}

# Map detection to flashability / outcome buckets
cerro_is_flashable() {
  case "$1" in
    edl|fastboot) return 0 ;;
    fastboot_hint|fastboot_noperm)
      # try chmod like Uotan, then re-check
      return 1 ;;
    *) return 1 ;;
  esac
}

cerro_wait_mode() {
  # $1 = comma list of accepted modes; $2 = timeout seconds
  local want=${1:-edl,fastboot}
  local timeout=${2:-300}
  local start=$SECONDS mode
  local dump_noted=0
  echo "waiting for mode in [$want] (timeout ${timeout}s)…"
  while (( SECONDS - start < timeout )); do
    mode=$(cerro_detect_stable 2 0.4)
    case ",$want," in
      *",$mode,"*)
        echo "got mode=$mode"
        return 0
        ;;
    esac
    if [[ "$mode" == fastboot_noperm || "$mode" == fastboot_hint ]]; then
      if [[ -d /dev/bus/usb ]]; then
        sudo chmod -R a+rw /dev/bus/usb 2>/dev/null || true
      fi
    fi
    if [[ "$mode" == dump ]]; then
      if (( dump_noted == 0 )); then
        echo "NOTE: MemoryDump (19d2:0112) — 强制关机后音量±进 9008"
        dump_noted=1
      fi
      # Signal caller: dump while waiting often means previous "PASS" was wrong
      echo "DUMP_WHILE_WAITING"
      return 2
    fi
    if (( (SECONDS - start) % 20 == 0 )); then
      echo "[$(date +%H:%M:%S)] now=$mode"
    fi
    sleep 1
  done
  echo "TIMEOUT waiting for [$want] (last=$(cerro_detect_raw))"
  return 1
}

cerro_detect_detail() {
  echo "raw=$(cerro_detect_raw) stable=$(cerro_detect_stable 2 0.3)"
  echo "fastboot devices:"; fastboot devices 2>&1 || true
  echo "lsusb interesting:"; lsusb 2>/dev/null | grep -iE '05c6|18d1|19d2|Qualcomm|Google|ZTE' || echo '(none)'
}
