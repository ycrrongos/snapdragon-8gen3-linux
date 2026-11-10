# Port another Snapdragon 8 Gen 3 / SM8650 device

Reusable pieces include the pinned mainline baseline, CAMSS C-PHY work,
modem/IPA investigations, native V4L2/libcamera approach and the evidence-driven
experiment method. A working Cerro kernel is not evidence for another board.

1. Identify exact SoC/SKU/board, boot image topology and a demonstrated unlocked
   boot/recovery path. Preserve original partitions and device-unique calibration
   privately with per-slot names and checksums. Do not publish EFS/persist/NV.
2. Start with the upstream SM8650 DTSI. Compare board supplies, pinctrl, resets,
   interconnects, clocks, reserved memory, firmware names and panel timings.
   Use upstream bindings and peer Linux ports, then stock behavior as evidence.
3. Establish serial/USB/network observability before display/camera experiments.
   A black screen alone does not prove a boot failure. Observe USB identities,
   boot ID and DHCP rediscovery; use bounded but sufficiently long boot windows.
4. Change one hardware variable per experiment. For a camera, verify power-off
   ID reads, the exact module/sensor and lens, mode timing/C-PHY link frequency,
   actual RAW and Bayer order, focus/exposure, power release and real cold boot.
5. Preserve separate acceptance for nodes, runtime behavior, boot persistence
   and a usable GUI. Do not hide missing dependencies behind delayed timers or
   login-time restarts. Bind to actual suppliers in their proper order.

Record upstream provenance and retain all license/author notices. Linux drivers
are the integration target: do not transplant the whole Android HAL/session model.
