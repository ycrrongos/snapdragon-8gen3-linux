# Cerro SM8650 C-PHY receive experiment

RAW transport passed: three2048×1152 pBAA frames, consecutive sequence numbers,
33.3ms intervals, 2949120bytes/frame. Stop returned sensor runtime PM and all
four camera supply votes to0. First image content was near black level64;
optical-scene and control verification remain open. This is not final camera
or GUI acceptance.

`0001-camss-cphy-sm8650-mode7.patch` applies to the known Cerro kernel tree
7b732bdca. Tree623df67b0 contains the same CAMSS-only change; no Image or boot
was rebuilt. Build only the module with:

```
make -C build/linux-7.2 ARCH=arm64 LLVM=1 LOCALVERSION= -j10 M=drivers/media/platform/qcom/camss modules
patches/camera-cphy-c1/build-graph.sh
```

Protocol groundwork is adapted from David Heidelberg's
[C-PHY series](https://codeberg.org/sdm845/linux/commits/branch/b4/qcom-cphy),
ending bb02f438efef39cbc18c4e8e951ae36180298aa0. The first7 commits apply to
this baseline; link-frequency and endpoint changes were adapted to its older
API. Attribution/review history remains in the referenced primary series.
The adapted patch does not claim upstream acceptance.

Board-specific receiver facts were cross-checked against the locally held
Nubia SM8650 camera-kernel `cam_csiphy_2_2_0_hwreg.h`, `cam_csiphy_soc.c`,
`cam_csiphy_core.c`, `cam_ife_csid780.h`, and CamX CreateCSIPHYConfig:

- CSID Gen3 PHY_TYPE bit24 (the SDM845 series only covered Gen2).
- v2.2.0 base3PH table and standard-channel2.5Gsps bucket selected by factory
  mode7 OPclk×10/3=4562300000 bits/s. Do not use the telephoto variant or the
  sc7280/SDM845 electrical table.
- Stock settleTimeNs serialization multiplies by200000000 and the driver
  divides by it: mode7's hardware count is25. It is not independently measured
  nanoseconds to reconvert.
- v2.2.0 C-PHY receive clock vote is per-trio bit rate/32; the old D-PHY clock
  rule is inapplicable. Only the currently audited factory link is accepted.
- V4L2 LINK_FREQ is998MHz, two symbols/cycle, from the1.996Gsymbol/s OP PLL.
  See [the kernel transmitter/receiver contract](https://docs.kernel.org/driver-api/media/tx-rx.html#pixel-rate).

`camera-graph-overlay.dts` adds only the sensor's Titan GDSC dependency and
C-PHY connection to CSIPHY1. The loader checks Cerro identity and has no
remove/reapply path. Its FDT byte array **must be8-byte aligned**; libfdt rejects
a misaligned embedded pointer even when the DTB file merges correctly offline.
The existing ID overlay node/supplies are prerequisites for this runtime-only
experiment. Permanent board DT integration remains required.

Before module replacement, check for open video/media users, preserve the
existing module files, and remove only the named camera modules with rmmod.
`modprobe -r` also attempts shared dependencies and can fail after removing
the target successfully. Do not force-remove an in-use media dependency.
Sensor runtime PM requires a Titan power-domain reference independently of
CAMSS; preserving CAMSS merely to make its MCLK work would hide the dependency.

Use the feature note for exact running/deployed artifact identities and all
failed intermediate states. No raw scene frames belong in git.

## Factory mode1 extension

`0002-camss-cerro-mode1-link-frequency.patch` extends the explicit SM8650
C-PHY whitelist from998MHz to the two audited frequencies998MHz and1GHz.
Kernel treeaf975f9ca contains it, without an Image rebuild. The hash-locked
factory mode1 record has OPclock1371430000,30fps,3trios,settle25 and3phase1;
it uses the same electrical bucket/settle as mode7. Formula and register table
are unchanged. No arbitrary frequency is accepted. Real4096×3072 RAW and
4088×3072 RGB passed30fps; mode7 regression and4rail release also passed.
See the feature note for exact artifacts and remaining quality/startup work.
