# Correct USB adapter reporting on Cerro

Upstream author: Joonhoe Kim <26rote@gmail.com>.
Reviewed-by in upstream submission: Kamal Wadhwa.
Source: https://lists.openwall.net/linux-kernel/2026/10/12/1411
License: kernel source SPDX GPL-2.0-only.

Same two-line upstream correction, integrated into kernel/cerro.patch: request
USB_ADAP_TYPE(7), not USB_TYPE(6), and decode the matching response. On this phone
with an owner-provided65W supply, UCSI confirmsPD and actualUSB input is8.9V/2.8A,
while the old USB_TYPE incorrectly saysSDP. The corrected battery-manager module
reportsPD without changing input-current policy, configuration or ABI.

This fixes reporting, not charging power. The observed source supplies about25W,
not its entire65W nameplate rating. Do not force current or claim all proprietary
fast-charge modes work. The previous PC SDP input was limited500mA; its source
capabilities must be respected.

Build only the module with the exact deployed C3 configuration:

```sh
make -C build/linux-7.2 ARCH=arm64 LLVM=1 -j8 M=drivers/power/supply qcom_battmgr.ko
```

Keep the current Image and other modules unchanged. Before install preserve the
existing qcom_battmgr module and depmod metadata, compare identity/source/ABI,
then reload ONLY qcom_battmgr with a tested rollback. Never unload pmic_glink,
UCSI or IPA for this reporting fix. A future kernel configuration/ABI change
requires the full matching module closure. No unconditional phone installer is
provided because source/slot/ABI preconditions are deployment-specific.

Live reload with65W source reportsPD at unchanged~25W, same boot/SSH/desktop.
Persistent module installed; cold reboot/replug/long charging trend evidence is
tracked in notes/features/20261113-charging.md, not inferred from module loading.
