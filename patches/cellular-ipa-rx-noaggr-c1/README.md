# cellular-ipa-rx-noaggr-c1

## Purpose
Diagnostic: disable aggregation on IPA `AP_MODEM_RX` (GSI ch1 / EP23) and
shrink RX buffer to 2048. If RX packets appear after load, the stock
aggregation path is implicated in cerro's TX>0/RX=0 symptom.

Also includes the already-applied `cellular-ipa-gsi-stop-c1` STOP/force-close
changes when built from the patched `build/linux-7.2` tree.

## Build
```bash
cd build/linux-7.2
# phone.config + modules_prepare already done once
make ARCH=arm64 LLVM=1 KBUILD_MODPOST_WARN=1 M=drivers/net/ipa modules
```
Vermagic must be `7.2.0-rc5-dirty SMP preempt mod_unload aarch64`.

## Install
Replace `/lib/modules/$(uname -r)/kernel/drivers/net/ipa/ipa.ko` and reboot.
Do **not** live `rmmod ipa` / stop MPSS on cerro — GSI STOP hangs the SoC
(observed 2026-10-16).
