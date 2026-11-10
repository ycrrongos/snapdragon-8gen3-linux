# stability-ipa-imem-c1

This is an offline-only, exact-C3 binary DTB candidate for Cerro's recurring
whole-device reset loop.

## Evidence

After `stability-adsp-serialize-c1`, multiple boots successfully reached both
registered cellular and a working ADSP/ALSA/KDE audio graph, then still reset.
Two live boots preserved the same apps-SMMU translation fault:

- stream ID `0x4a0` (IPA AP context);
- IOVA `0x14684080`;
- FSR `0x402`, context bank 5 / S1CBNDX 58.

The stock AOSP `pineapple-ipa.dtbo` maps
`0x14683000..0x14684fff` into that IPA context. The current mainline Cerro DTB
instead supplies `0x14688000..0x14689fff` through the IPA `sram` phandle, so
the exact fault IOVA is not mapped.

## Exact delta

The build starts from the actually flashed C3 boot image, SHA-256
`211bfa98e499e683181a67d6f5c140bc9a96ab2074e91e1a12e2b9fcd335cdf5`.
It changes only the existing DT property:

```dts
/soc@0/sram@14680000/modem-tables@8000 {
    reg = <0x8000 0x2000>;
};
```

to:

```dts
/soc@0/sram@14680000/modem-tables@8000 {
    reg = <0x3000 0x2000>;
};
```

The node name remains unchanged because it is not used to derive the resource.
The property edit is exactly one byte (`0x80 -> 0x30`) in each of the three
identical DTB copies: built into the arm64 Image, appended after ImageSize, and
the boot header's separate DTB component. Kernel code, initramfs, command line,
partitions and all other DT properties remain byte-identical to C3. As required
by boot image v2, `mkbootimg` also recomputes the 20-byte header ID digest; the
audit accepts those derived header bytes plus exactly the three payload bytes
and nothing else.

## Build and scope

Run `./build.sh`. It first proves an untouched C3 repack is byte-identical,
verifies all component hashes/sizes and both kernel DTB offsets, applies the
three-byte payload patch, validates the recomputed header ID, re-unpacks the
result and writes a hash manifest under `out/`.

The build script has no phone, USB, EDL, fastboot, qboot, QMI, remoteproc,
mount, EFS or partition action. Flashing is deliberately outside this
candidate and requires separate explicit authorization.
