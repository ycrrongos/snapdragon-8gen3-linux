# cellular-ipa-wan-ep-c1

## Why
Aurora downstream IPA v5.5 (`ipa_utils.c` `IPA_CLIENT_APPS_WAN_CONS`) uses
**endpoint 24 / GSI channel 1** for modem→AP data. Endpoint 23 on this
generation is `APPS_WAN_COAL_CONS` (channel 4). Mainline `ipa_data-v5.5.c`
still has the IPA v5.0 pair (EP 23 / ch 1). Modem DL is therefore aimed at
a pipe the AP is not listening on, which matches cerro **TX>0 RX=0**.

`IPA_CLIENT_Q6_WAN_CONS` likewise moved from EP 21 (v5.0) to EP 22 (v5.5).
That is mainline `IPA_ENDPOINT_MODEM_AP_RX`.

UL `APPS_WAN_PROD` stays EP 2 / ch 11 and already matches, which is why TX works.

## Install
Replace `ipa.ko`, then **hard power-cycle**. Do not `rmmod ipa` and do not
`systemctl reboot` (IPA STOP hangs). Do not `AGGR_FORCE_CLOSE`.

## 2026-11-10 deployment regression

The current committed kernel tree contains the fix, but the rootfs still loaded
an older IPA module: the **running** sysfs endpoint was 23. CMNET bearer/IP
succeeded, while device-bound HTTPS had TX>0/RX=0. Source presence is insufficient.

Build modules from the current clean tree (record `git rev-parse HEAD`):
`make -C build/linux-7.2 ARCH=arm64 LLVM=1 LOCALVERSION= -j10 modules`.
A single `M=drivers/net/ipa` build may lack module-to-module QMI exports in
Module.symvers; do not ignore modpost unresolved symbols. Only deploy IPA.
Strip debug on a copy, preserve original distro module, install into
`updates/cerro-cellular-ipa-c1`, run depmod and verify modinfo priority/vermagic.
`install-current-module.sh PATH SHA256` implements this staging only.

Current staged module SHA256:
`3360bbaaca7505917028f8ca7f53a3d6aabc2f658a3b72587255821aff0d3039`
from tree `7b732bdca46c058316ec41e726da3f77ab1e9eab`.
It does not replace the boot image or other modules. Do not unload the old
active IPA; use a full reboot/power cycle. After boot require actual sysfs
`/sys/devices/platform/soc@0/3f40000.ipa/modem/rx_endpoint_id` = 24, stable
MPSS/ADSP and end-to-end data.

`sudo python3 test-bound-data.py qmapmux0.0` binds the socket with
SO_BINDTODEVICE, validates TLS/HTTP against two hosts, and prints interface
byte counters. It cannot silently fall back to Wi-Fi. This probe is useful
when curl is absent. A connected bearer is not a successful data test.
