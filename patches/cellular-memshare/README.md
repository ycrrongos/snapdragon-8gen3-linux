# cellular-memshare — Cerro DHMS service 52 candidate

This directory contains a Linux 7.2 API port of Qualcomm's Dynamic Heap
Memory Sharing QMI service (`0x34`, version 1, instance 1). It closes the
stock-vs-mainline gap observed during the AOSP cellular round-trip.

## Evidence and scope

On the exact Cerro AOSP build, MPSS starts, queries client 1, requests exactly
5 MiB, receives a successful physical allocation, and only then initializes
IPA and connects DMS. The evidence is retained in
`notes/bisect-logs/aosp-cellular-roundtrip-20260817/`.

The protocol tables derive from Android common kernel commit `3b3e314b...`.
The service core was rewritten around maintained Linux 7.2 APIs:

- QMI requests `0x22`, `0x23`, and `0x24` retain the downstream wire layout;
- DMA/CMA supplies contiguous memory with no kernel mapping;
- `qcom_scm_assign_mem()` grants MPSS access before returning success;
- only DT-listed clients and their exact configured sizes are accepted;
- allocate-on-request buffers persist across modem restarts, matching the
  downstream behavior, and are reclaimed when the module is removed;
- downstream-only subsystem-restart notifier, ramdump, and secure-buffer APIs
  are intentionally omitted.

The Cerro DTS carries all five stock clients. Client 1 is the observed 5 MiB
request. Client 5 retains the stock 16 MiB reusable shared DMA pool; clients 5
and 6 keep HLOS access when MPSS access is granted.

## Build and boot ordering

`tools/cerro-debian/build-boot.sh` builds `qcom-memshare.ko`, checks exact
kernel vermagic and dependencies, installs it into the embedded initramfs,
runs `depmod`, and verifies the final archive. `tools/cerro-init/init` loads it
after `qmi_helpers` and before `qcom_q6v5_pas`, so service 52 is advertised
before the first MPSS start.

Host validation completed before device testing:

- normal and `W=1` external-module builds;
- strict `checkpatch.pl` with zero findings;
- binding validation, example validation, and the Cerro DT instance check;
- compiled DT inspection for five clients, their exact sizes/IDs, the shared
  pool, and a unique per-candidate `cerro_dtb` marker.

This remains a device candidate until a controlled boot proves the QMI query,
5 MiB allocation, service 52 route, and resulting DMS state on Linux.

## Device result and current candidate

C3 booted successfully and the driver registered all five clients plus
service52 when installed live. Its first cold boot missed the module because
the generic initramfs staging copied modules into the outer userdata root,
while native Debian switch-roots into `/debian-root`. The late recovered MPSS
start did not issue the stock query/allocation transaction, so it is not a
valid cold-boot causal result. `C3-BOOT.sha256` retains the exact flashed boot
and stock `vendor_boot` hashes.

The current unflashed C4 candidate is
`build/boot_repack/boot-v2-disp-dpu-s5gb-debian-cellular-c4-memshare-native-stage.img`
(78,012,416 bytes, SHA-256
`a3dd1425ec6737cda2dbfd9ed94590420bb1181af6f6c98e527b002ea1eb014f`).
It copies the exact module into the bound native-Debian root, runs target-root
`depmod`, and loads service52 before native systemd/rmtfs. Its filename is
`boot-v2-disp-dpu-s5gb-debian-cellular-c4-memshare-native-stage.img`.
`CANDIDATE.sha256` locks the boot image, its Image/initramfs/module/DTB inputs,
and both retained stock `vendor_boot` sources. Run `sha256sum -c` from the
repository root before any device operation.
