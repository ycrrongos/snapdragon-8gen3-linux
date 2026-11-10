#!/bin/sh
# Stage the verified same-kernel IPA module. No unload/reboot/service mutation.
set -eu
src=${1:?ipa.ko path required}
expected=${2:?SHA-256 required}
release=$(uname -r)
test "$(id -u)" = 0
test "$release" = 7.2.0-rc5-dirty
test "$(sha256sum "$src" | cut -d' ' -f1)" = "$expected"
test "$(modinfo -F vermagic "$src")" = '7.2.0-rc5-dirty SMP preempt mod_unload aarch64'
base=/usr/local/share/cerro-backups/ipa-20261110
install -d "$base" "/lib/modules/$release/updates/cerro-cellular-ipa-c1"
cp -n "/lib/modules/$release/kernel/drivers/net/ipa/ipa.ko" "$base/ipa-original.ko"
install -m 0644 "$src" "/lib/modules/$release/updates/cerro-cellular-ipa-c1/ipa.ko"
depmod -a "$release"
modinfo -n ipa
sha256sum "$base/ipa-original.ko" "/lib/modules/$release/updates/cerro-cellular-ipa-c1/ipa.ko"
sync
