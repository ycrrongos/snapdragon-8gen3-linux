# cerro embedded init

Source for `build/linux/usr/cerro-initramfs.cpio.gz` → baked into `Image` via `CONFIG_INITRAMFS_SOURCE`.

**s5bv+**：`/init` mounts `pmOS_root` and `switch_root` → `cerro-sd-prep` → systemd.  
UI on rootfs is **`postmarketos-ui-console`** (getty login, not phosh/weston).  
Typical login: `user` / `user` (this image’s shadow hash; not 147147).

**Native Debian selector**: the dedicated boot image contains the initramfs
marker `/cerro-userland-debian` and also requests the kernel cmdline token
`cerro_userland=debian`. The marker is authoritative because Cerro ABL drops
the boot-header cmdline addition on this handset. The selector bind-mounts
`/debian-root` as a real mountpoint and executes `switch_root` into its
`/cerro-sd-prep`. Debian systemd then runs as PID 1; this is not a
chroot/container runtime. The selector refuses to switch unless
`/debian-root/.cerro-native-debian`, `/sbin/init`, and `/cerro-sd-prep` are all
present. Images without the marker or cmdline token keep the existing pmOS
path.

## Host → 9008 after PASS

After switch_root, ACM gadget may go away. Prefer servo hand:

```bash
tools/edl-tools/enter-9008-hand.sh
```

## Repack after editing `init`

```bash
rm -rf /tmp/cerro-ird && mkdir /tmp/cerro-ird && cd /tmp/cerro-ird
zcat /mnt/data/LOA_Nubia_Z60U/build/linux/usr/cerro-initramfs.cpio.gz | cpio -idm
cp -a /mnt/data/LOA_Nubia_Z60U/tools/cerro-init/init ./init
find . -print0 | cpio --null -o -H newc --owner=0:0 | gzip -9 \
    > /mnt/data/LOA_Nubia_Z60U/build/linux/usr/cerro-initramfs.cpio.gz
cd /mnt/data/LOA_Nubia_Z60U/build/linux
rm -f usr/initramfs_data.cpio usr/initramfs_inc_data
make ARCH=arm64 LLVM=1 -j$(nproc) Image
```

## s5eq BT notes

- Plants kiwi/hamilton firmware under `/lib/firmware/qca/` and BT modules for `7.2.0-rc5-dirty`.
- Fixes `/etc` ownership with **`chown 0:0`** (name `root` fails without passwd in initramfs).
- `cerro-bt.service` load order: `rfkill kpp ecc ecdh_generic bluetooth btbcm btqca hci_uart`.

## s5es WiFi notes

- Also stages `/lib/firmware/ath12k/` when present in initramfs (see `notes/firmware-kiwi/ath12k-WCN7850-hw2.0/`).
- Modules: `libarc4 cfg80211 mac80211 qmi_helpers ath12k ath12k_wifi7` (mhi is builtin).
- **Need both** `ath12k.ko` and `ath12k_wifi7.ko` — PCI IDs live in wifi7.
- Board lookup key for cerro: `…subsystem-device=1107,qmi-board-id=255` (not in stock board-2 alone).
- `cerro-wifi.service` brings up `wlan0`.
