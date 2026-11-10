# Reproducible source build

## Scope and prerequisites

The supported clone build produces an ARM64 Image, Cerro DTB and kernel modules.
It is separate from an installed Debian rootfs and from phone boot-image packaging.
Use the README packages. The recorded host compiler is clang 23.1.4; other LLVM
versions have not all been verified. Allow approximately 15–25 GB free space.

`make prepare` fetches the exact upstream tag, checks its full commit, verifies
both local patch/config hashes, checks patch applicability and atomically installs
`build/linux-7.2`. It refuses an existing directory. It never resets a kernel tree.
For a local offline mirror:

```sh
python3 tools/prepare-kernel.py --source /path/to/linux-git --dest build/linux-7.2
```

The mirror must contain the locked upstream commit. Its local changes are not
copied. `KERNEL_DIR=/path/to/prepared/tree OUTPUT_DIR=/path/to/output JOBS=8 tools/build-source.sh` supports a separate prepared tree. The source readiness
record is `.cerro-source.json`. Checksums record inputs, not bit-for-bit compiler
reproducibility across different toolchains and build timestamps.

## External drivers

After the full kernel build, these compile native camera and memshare modules:

```sh
export KERNEL_DIR="$PWD/build/linux-7.2"
make -C "$KERNEL_DIR" ARCH=arm64 LLVM=1 LOCALVERSION= M="$PWD/patches/camera-imx800-c1" modules
KERNEL_DIR="$KERNEL_DIR" sh patches/camera-board-c1/build.sh
KERNEL_DIR="$KERNEL_DIR" sh patches/camera-optics-c1/build.sh
make -C "$KERNEL_DIR" ARCH=arm64 LLVM=1 LOCALVERSION= M="$PWD/patches/cellular-memshare" modules
```

No private EEPROM is needed to compile. Running a lens requires calibration
read from that particular phone; the loader validates it at runtime. Never use
another handset's calibration. `patches/camera-userspace-c1` and
`patches/camera-gui-c1` contain libcamera 0.8.0 helper and qcam controls; the
current native-on-phone build recipe documents its staging sysroot. It is a
tested development GUI, not the promised final general-purpose camera app.

## Boot images and deployment

`tools/cerro-build-boot.sh LABEL` is the existing phone's full boot-packaging
entry, requiring a locally verified `REF_BOOT` and the matching known-good
embedded initramfs. The public source build deliberately does not fabricate
those private deployment inputs. Default source outputs are **not flashable**.
Do not substitute an arbitrary Android ramdisk. Packaging is header v2, page4096,
127-byte stub, Image padding to its ARM64 `image_size`, appended DTB and96MiB
partition bounds. Audit the actual embedded init, including ACM logging gate,
early DRM dependencies and merged-/usr handling before any new phone trial.

On the already provisioned, unlocked test phone, current host switching uses:

```sh
python3 tools/cerro-dualboot/host/switch-system.py status
tools/cerro-dualboot/host/switch-to-linux.sh --dry-run
```

Read `tools/cerro-dualboot/host/SWITCHING.md` before a real switch. Android
boot/dtbo are cached into the inactive slot then Linux boot + zero dtbo replace
the **same active slot**; switching back restores those two files without
changing GPT active selection. Full host backups, labels and readback checks
are mandatory. These tools do not install a rootfs or repartition a new phone.
Do not run historical repartition/dual-slot flash scripts to follow this recipe.

## Evidence

See `docs/BUILD-VALIDATION.md` for the release's fresh-tree build results.
Compile success does not establish a new kernel's phone runtime behavior.

The cross-compile commands follow the [Linux LLVM build documentation](https://docs.kernel.org/kbuild/llvm.html).
