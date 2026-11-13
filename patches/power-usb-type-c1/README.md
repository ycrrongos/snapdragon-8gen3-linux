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

## Standard input-current interface (C2)

Also integrates Joonhoe Kim's upstream setter:
https://lkml.iu.edu/hypermail/linux/kernel/2610.0/12428.html . It exposes the root-only
standard input_current_limit property and completes USB_PROPERTY_SET responses.
No unconditional current increase is included. A negative request is rejected
before firmware I/O. C2module was live-loaded with the sameC3configuration; PD
input remains unchanged. A positive limit request requires source-specific
capability evidence and actual current/readback validation, not just write success.

## Cerro SDP policy

`policy/cerro-usb-current.py` handles normal udev add/change events; it has no
polling timer or service restart. The quirk is specific to Cerro's verified SDP
firmware class reporting current_max=900000uA, matching the earlier Android
same-PC behavior. It never exceeds that reported maximum, touches PD/DCP, raises
above900mA, or writes while temperature>=40C / voltage outside4.5–5.5V. Firmware
thermal/current regulation remains enabled. Unknown source classes are skipped;
this is not a guarantee that every ordinaryUSBport can provide900mA.

Install the matching patched module first, then install the helper0755 under
/usr/local/libexec and rule0644 under/etc/udev/rules.d; reload udev rules. Normal
coldplug/hotplug invokes it. An already-correct limit does not cause another
write. On the observed PC port, a bounded900mA request yields831mA input rather
than453mA, with positive battery current. Simulated change-event recovery is
verified; physical hotplug and cold-start evidence are tracked separately.

Rollback removes only this rule/helper, reloads rules, and restores the previously
observed input_current_limit if still on the same source. Original modules are
backed up separately. Do not remove/reload pmic_glink/UCSI/IPA for this policy.

Offline safety cases:

```sh
python3 patches/power-usb-type-c1/policy/test_policy.py
```
