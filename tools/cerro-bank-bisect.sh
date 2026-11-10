#!/usr/bin/env bash
# Binary-search CERRO_FALLBACK/SAFE_MAP size at MAP_MEM_STEP=3 (stage31 PSCI).
# Encoded steps: 30000+MiB. Known-good floor: 256MiB. Old guess ceiling: 9600MiB.
#
# Usage:
#   SKIP_UNLOCK=1 ./tools/cerro-bank-bisect.sh
#   SKIP_UNLOCK=1 LO_MIB=256 HI_MIB=9600 ALIGN_MIB=256 ./tools/cerro-bank-bisect.sh
#
set -euo pipefail

ROOT=/mnt/data/LOA_Nubia_Z60U
BISECT="$ROOT/tools/cerro-map-bisect.sh"
TSV="$ROOT/notes/bisect-logs/map-bisect.tsv"
NOTES="$ROOT/notes/cerro-linux-bringup.md"

LO_MIB=${LO_MIB:-256}       # last known PASS
HI_MIB=${HI_MIB:-9728}      # 0x260000000 exactly (9728 MiB)
ALIGN_MIB=${ALIGN_MIB:-256}

last_outcome() {
  local enc="$1"
  awk -F'\t' -v s="$enc" '$2 == s { o=$3; d=$4 } END { print o "\t" d }' "$TSV"
}

is_pass() {
  [[ "$1" == pass ]]
}

is_fail() {
  case "$1" in
    early_fastboot|dump|hang) return 0 ;;
    *) return 1 ;;
  esac
}

run_enc() {
  local mib="$1"
  local enc=$((30000 + mib))
  local out_file="$ROOT/notes/bisect-logs/.bank-last-outcome"
  echo ""
  echo "======== BANK ${mib}MiB (enc=$enc) ========"
  env -u PASS_MIN_S -u OBSERVE_S -u QUIET_EXTEND_S -u UNLOCK_WAIT_S \
    SKIP_UNLOCK="${SKIP_UNLOCK:-1}" MIN_PASS_CYCLES="${MIN_PASS_CYCLES:-2}" \
    QUIET_POLICY="${QUIET_POLICY:-hang}" \
    "$BISECT" "$enc"
  local row outcome detail
  row=$(last_outcome "$enc")
  outcome=${row%%$'\t'*}
  detail=${row#*$'\t'}
  echo "BANK ${mib}MiB → outcome=$outcome detail=$detail"
  printf '%s\n' "$(date -Iseconds)	meta	bank_bisect	${mib}MiB_${outcome}	${detail}" >>"$TSV"
  printf '%s' "$outcome" >"$out_file"
}

align_down() {
  local x="$1" a="$2"
  echo $(( (x / a) * a ))
}

main() {
  echo "==== cerro-bank-bisect $(date) ===="
  echo "LO_MIB=$LO_MIB (PASS floor) HI_MIB=$HI_MIB ALIGN=$ALIGN_MIB SKIP_UNLOCK=${SKIP_UNLOCK:-1}"

  local hi_out
  run_enc "$HI_MIB"
  hi_out=$(cat "$ROOT/notes/bisect-logs/.bank-last-outcome")
  if is_pass "$hi_out"; then
    echo "CEILING PASS: full ${HI_MIB}MiB map_mem OK with low-end pt alloc"
    printf '%s\n' "$(date -Iseconds)	meta	bank_bisect	ceiling_pass_${HI_MIB}MiB	map_mem_tolerates_oversized_bank" >>"$TSV"
    echo "RESULT lo=$LO_MIB hi_pass=$HI_MIB (no fail found)"
    exit 0
  fi
  if ! is_fail "$hi_out"; then
    echo "CEILING inconclusive ($hi_out) — stop"
    exit 3
  fi

  local lo=$LO_MIB hi=$HI_MIB mid mid_out
  while (( hi - lo > ALIGN_MIB )); do
    mid=$(align_down $(( (lo + hi) / 2 )) "$ALIGN_MIB")
    if (( mid <= lo )); then
      mid=$((lo + ALIGN_MIB))
    fi
    if (( mid >= hi )); then
      break
    fi
    run_enc "$mid"
    mid_out=$(cat "$ROOT/notes/bisect-logs/.bank-last-outcome")
    if is_pass "$mid_out"; then
      lo=$mid
    elif is_fail "$mid_out"; then
      hi=$mid
    else
      echo "inconclusive at ${mid}MiB ($mid_out) — stop"
      exit 3
    fi
    echo "window: PASS<=${lo}MiB  FAIL>=${hi}MiB"
  done

  echo "RESULT last_pass=${lo}MiB first_fail=${hi}MiB align=${ALIGN_MIB}MiB"
  printf '%s\n' "$(date -Iseconds)	meta	bank_bisect	last_pass_${lo}MiB_first_fail_${hi}MiB	align_${ALIGN_MIB}" >>"$TSV"
}

main "$@"
