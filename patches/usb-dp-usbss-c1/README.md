# Cerro native WCD939x USBSS DP AUX route

Base tree: 0fa0bde4eebdfd753f5cee883a54999b3fabd280.
Tree commit: 6e5332b110683133110819b065347d98bc236311.

Patch adds only the a8c000 I2C controller / 0e USBSS child / L15B supply and connector port2 graph. Aurora Cerro source and the saved slot-A vendor_boot+dtbo agree on this route. No unproven GPIO152 reset copied from QRD. Audio headset graph remains a separate feature.

Kernel config already has TYPEC_MUX_WCD939X_USBSS=m. Build the selected existing module with:

```sh
make -C build/linux-7.2 ARCH=arm64 LLVM=1 LOCALVERSION= -j10 drivers/usb/typec/mux/wcd939x-usbss.ko
```

Transfer the ko through Wi-Fi. Check SHA and vermagic against uname before installing directly to `/usr/lib/modules/<kver>/updates/cerro-dp4/wcd939x-usbss.ko`; depmod; `/etc/modules-load.d/cerro-usbss.conf` contains `wcd939x-usbss`. Do not extract an archive over `/lib`.

For the Image/DTB use only `JOBS=10 tools/cerro-build-boot.sh usb-dp4-usbss`. Details, exact SHA, dual-slot readback and pending runtime outcome: `notes/features/20261109-dp-usbss.md`.

Status at 2026-11-09 22:50: build and dual-slot readback succeeded; reboot issued but no Wi-Fi return yet. Boot and external output remain unverified. Do not call this DP PASS.
