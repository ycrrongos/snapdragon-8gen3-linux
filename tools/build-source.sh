#!/usr/bin/env bash
# Compile source artifacts without requiring a private boot image or accessing a phone.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
K=${KERNEL_DIR:-$ROOT/build/linux-7.2}
OUT=${OUTPUT_DIR:-$ROOT/build/artifacts}
[[ -f "$K/.cerro-source.json" ]] || { echo 'Run python3 tools/prepare-kernel.py first (use a new directory).' >&2; exit 2; }
export LOCALVERSION=
JOBS=${JOBS:-$(nproc)}
make -C "$K" ARCH=arm64 LLVM=1 olddefconfig
make -C "$K" ARCH=arm64 LLVM=1 -j"$JOBS" dtbs
cp "$K/arch/arm64/boot/dts/qcom/sm8650-nubia-cerro.dtb" "$K/arch/arm64/kernel/sm8650-nubia-cerro.dtb"
make -C "$K" ARCH=arm64 LLVM=1 -j"$JOBS" Image modules
mkdir -p "$OUT"
cp "$K/arch/arm64/boot/Image" "$OUT/Image"
cp "$K/arch/arm64/boot/dts/qcom/sm8650-nubia-cerro.dtb" "$OUT/"
cp "$K/.config" "$OUT/kernel.config"
make -C "$K" ARCH=arm64 LLVM=1 INSTALL_MOD_PATH="$OUT/modules" modules_install
cp "$K/.cerro-source.json" "$OUT/source.json"
(cd "$OUT" && sha256sum Image sm8650-nubia-cerro.dtb kernel.config > SHA256SUMS)
printf 'Compiled source artifacts: %s\n' "$OUT"
