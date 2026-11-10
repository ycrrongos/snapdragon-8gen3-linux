# Fresh source-build validation

2026-11-10, Linux x86_64 host, clang23.1.4, targetARM64.

- Exact upstream v7.2-rc5/f5098b6bae761e346ebcd9da7f95622c04733cff.
- New directory, upstream exported from an optional local git mirror; the port
  patch was applied once after its applicability/hash checks. No prebuilt object,
  private initramfs, rescue image, firmware, calibration or Android source used.
- `KERNEL_DIR=.../public-clean-kernel OUTPUT_DIR=.../public-clean-artifacts
  JOBS=12 tools/build-source.sh`: exit0, DTBs/Image/fullmodules/modules_install.
- The built-in Cerro DTB was copied from the newly compiled board DTB before
  Image linking. Modules were installed with depmod metadata.
- External builds from the exported public sources: IMX800, board graph,
  AK7316 and lens graph, memshare: all5 modules compiled/linked successfully.
- Public-copy `make test`:8 host same-slot swap fault tests passed; SMS address,
  UCS2/GSM7, multipart and Unicode boundary fixture groups passed.
- Export audit checks all manifest hashes, text/size/credential refusal,
  Python compile and Shell syntax.4 mocked USB target-selection cases passed.

Artifacts are source-build evidence, not a new phone runtime acceptance. The
running phone's prior DP6 image and camera checkpoint were not changed here.

Installed kernel modules: **1409**.

Artifact SHA-256:

```text
a099669405014a27628638694ca9ef22cecd385d6fb252b5a5870be6939d7bc2  Image
60b33eb5f12372cd00dc07d1d3259e41fa188109c6ecae5a624886a9fe8e2bfd  sm8650-nubia-cerro.dtb
c1c25716c210082d75017d94989161954cf95ff1d8af0f78d99ff103f5077bcb  kernel.config
```

External module SHA-256 (compiler/path changes may change bytes):

```text
3c735d6d7243a8dd1b178b9a77d95ca51e1ca167d987c796ccb0451f13e69129  cerro-camera-board.ko
5bcae0696a5ae91aa2ea31026d613a33ebba4e19c605871d38805a18d82d3ecc  imx800-cerro.ko
9c6ad3c46dffe0cf7783ffbf5bcc057e5ca85db9718a578462af1b417626b9ba  ak7316-cerro.ko
e1308d27cf8ac2efb08b32368e423d84019fbf5eedecb3e07411bf7596c17e80  cerro-camera-lens.ko
8cd853cb5feeee3f795858a80d9b0887c4bd4b14568812137a4bcf0461ac2368  qcom-memshare.ko
```
