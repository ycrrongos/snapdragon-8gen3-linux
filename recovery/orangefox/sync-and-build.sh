#!/usr/bin/env bash
# Sync OrangeFox 14.1 (A14+ / modern FBE) and build twrp_cerro.
# Prefer local clone: /mnt/data/orangefox-sync/orangefox_sync.sh
# Manifest: nebrassy platform_manifest_twrp_aosp -b twrp-14 (NOT gitlab fox_14.1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
FOX_ROOT="${FOX_ROOT:-/mnt/data/orangefox-cerro}"
DT_SRC="$ROOT/device/nubia/cerro"
SYNC_DIR="${SYNC_DIR:-/mnt/data/orangefox-sync}"

# ArtistAOSP repo launcher + FlClash proxy
export PATH="${HOME}/bin:/mnt/data/ArtistAOSP/source/.repo/repo:${PATH}"
if [[ -f /mnt/data/ArtistAOSP/scripts/proxy-env.sh ]]; then
  # shellcheck disable=SC1091
  source /mnt/data/ArtistAOSP/scripts/proxy-env.sh
fi
if [[ ! -x "${HOME}/bin/repo" ]]; then
  mkdir -p "${HOME}/bin"
  cat >"${HOME}/bin/repo" <<'EOF'
#!/bin/bash
exec python3 /mnt/data/ArtistAOSP/source/.repo/repo/repo "$@"
EOF
  chmod +x "${HOME}/bin/repo"
fi

mkdir -p "$FOX_ROOT"

# Marker written by orangefox_sync.sh when fox vendor/recovery clones finish
MARKER="$FOX_ROOT/.ofox_sync_done"
need_sync=0
if [[ ! -d "$FOX_ROOT/.repo" ]]; then
  need_sync=1
elif [[ ! -f "$MARKER" ]]; then
  # Incomplete previous sync (e.g. killed mid repo sync)
  need_sync=1
elif [[ ! -d "$FOX_ROOT/bootable/recovery" ]]; then
  need_sync=1
fi

if [[ "$need_sync" -eq 1 ]]; then
  echo "==== syncing OrangeFox (14.1) into $FOX_ROOT ===="
  SYNC_SH="$SYNC_DIR/orangefox_sync.sh"
  if [[ ! -x "$SYNC_SH" ]]; then
    mkdir -p "$SYNC_DIR"
    curl -fsSL -o "$SYNC_SH" \
      https://gitlab.com/OrangeFox/sync/-/raw/master/orangefox_sync.sh
    chmod +x "$SYNC_SH"
  fi
  (cd "$SYNC_DIR" && ./orangefox_sync.sh --branch 14.1 --path "$FOX_ROOT")
  touch "$MARKER"
fi

cd "$FOX_ROOT"
mkdir -p device/nubia
rsync -a --delete "$DT_SRC/" device/nubia/cerro/

# shellcheck disable=SC1091
source build/envsetup.sh
export ALLOW_MISSING_DEPENDENCIES=true
# fox_14.1 / A14 lunch needs <product>-<release>-<variant>
lunch twrp_cerro-ap2a-eng
mka -j"$(nproc)" recoveryimage

echo "OK: $(ls -lh out/target/product/cerro/recovery.img)"
