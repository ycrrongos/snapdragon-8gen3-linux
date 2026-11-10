# OrangeFox for Nubia Z60 Ultra (cerro)

Device tree from **ArtistAOSP** `devices/nubia/cerro` + prebuilt kernel from Artist `boot.img`/`vendor_boot`.

## Build (host)

```bash
# Source tree: /mnt/data/orangefox-cerro (fox_14.1 / nebrassy twrp-14)
./sync-and-build.sh
# lunch: twrp_cerro-ap2a-eng
```

Artifacts land in `out/` (also copied from orangefox-cerro product out).

## Flash

```bash
fastboot flash recovery_a out/recovery.img
fastboot flash recovery_b out/recovery.img
adb reboot recovery
# or: fastboot boot out/OrangeFox-R12.0_A14-Unofficial-cerro.img
```

Partitioning helpers: `tools/cerro-dualboot/` — see `notes/cerro-dualboot.md`.

**Note:** QCOM FBE decrypt blobs are not yet copied from stock; resize.f2fs / GPT work does not need decrypt. Decrypt can be added later from Artist vendor.
