# Snapdragon 8 Gen 3 Linux — SM8650 / Nubia Z60 Ultra

Mainline Linux bring-up for **Qualcomm Snapdragon 8 Gen 3 (SM8650)**, currently
validated on **Nubia Z60 Ultra, NX721J, codename cerro**. Native Debian + KDE,
DRM/MSM, CAMSS/V4L2/libcamera, ModemManager and PipeWire; no Android HAL required
for the implemented Linux paths.

这是一个由 **ycrrongos 通过 vibecoding（AI 辅助编程与实机验证）**推进的项目。
It is a **vibecoding / AI-assisted development project**, with explicit hardware
checkpoints and unfinished work. Other SM8650 phones can reuse the approach and
SoC fixes; their panel, regulators, GPIOs, firmware and calibration need their
own board port. Cerro images are not universal Snapdragon phone images.

## Build after cloning

On a Debian/Ubuntu Linux build host (x86_64 cross-compiles ARM64):

```sh
sudo apt-get install git python3 make clang lld llvm flex bison bc \
  libssl-dev libelf-dev dwarves device-tree-compiler cpio rsync kmod

git clone https://github.com/ycrrongos/snapdragon-8gen3-linux.git
cd snapdragon-8gen3-linux
make prepare
JOBS=8 make build
make test
```

Pinned Linux **v7.2-rc5**, full commit and SHA-256-checked port patch/config are
in [`kernel/source.lock.json`](kernel/source.lock.json). No private local tree,
Android checkout, phone, firmware dump or rescue image is needed to compile.
Outputs: `build/artifacts/Image`, Cerro DTB, config, modules and checksums.
The empty initramfs in this **source build** is intentional: these outputs are
not a ready-to-flash OS or a complete Debian root filesystem.

See [build and deployment boundaries](docs/BUILDING.md) for external camera
modules, boot-image assembly and the existing-phone Android/Linux swap tools.
Building never flashes a device. A complete phone deployment still needs its
own lawful firmware, private per-unit calibration, prepared Linux rootfs and
verified recovery path.

## Current hardware checkpoint

As of 2026-11-10 on the tested Cerro:

- Internal display/touch/GPU/KDE, early kernel display, Wi-Fi, Bluetooth,
  battery reporting, USB ACM/ECM and OTG work.
- USB-C DisplayPort: direct 4K60 and tested HDMI adapter 4K30, display-mode
  transitions and hotplug recovered in the recorded tests.
- Dual SIM: both cards registered; actual mutual SMS and independent data
  sessions tested. LTE/5G NR observed. Calls are outside this checkpoint.
- Rear main IMX800: measured RGGB, 4096×3072 RAW / 4088×3072 RGB at 30fps,
  actual AK7316 focus, exposure controls, digital crop zoom and GUI JPEG.
  Normal boot prepares the graph in dependency order. The owner reports it
  is basically usable; this is not Android image-quality parity.
- Waydroid kernel interface and container-network tests passed; see [WAYDROID](docs/WAYDROID.md). Front/ultrawide/telephoto cameras,
  standard libcamera AF, improved existing-app UI, low light/AE, CCM/LSC/OIS,
  denoising and accelerometer integration remain open.

[STATUS](docs/STATUS.md) distinguishes measurements, user feedback and missing
features. [PORTING](docs/PORTING.md) helps adapt another Snapdragon 8 Gen 3 phone.
[AGENTS.md](AGENTS.md) and [QUICKSTART](docs/QUICKSTART.md) provide agent onboarding.

## Source layout

`kernel/` is the pinned complete in-tree port delta and config. `patches/`
contains standalone drivers, userspace patches, services and historical
experiments. `tools/` contains build, diagnosis and deployment tools. Experimental
installers are not a blanket instruction to run every script; start with the
current build/status documents. Old scripts may describe superseded slot layouts.

Project commits use the maintainer's GitHub identity. Upstream author/copyright
notices and licenses remain in source and [NOTICE](NOTICE); an upstream kernel
checkout is fetched during preparation rather than imported into this repo's
commit history. No firmware, device backups, subscriber identifiers, private
calibration, photos or old diagnostic history are published here.
