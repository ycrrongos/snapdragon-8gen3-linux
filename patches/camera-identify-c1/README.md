# Cerro one-shot main-camera identification

This is a read-only chip-ID experiment, **not a camera driver**. It does not
stream, program sensor modes, drive a lens/OIS, or enable the flash. Do not
install it as a boot service.

The overlay uses target-path and local phandle fixups: the existing DP6 DT has
no exported symbols. Its two literal phandles are verified against the live
Cerro tree before apply. `dtc -@` would create an unnecessary symbols table and
fails against this base; retain local fixups without exported symbols.

`build.sh` builds against the current `build/linux-7.2` module ABI, records the
module hash, and strips debug data only. No Image/boot/DTB rebuild occurs.
Generated `.inc`, `.dtbo`, `.ko`, `.o`, Module.symvers and Kbuild intermediates
are artifacts, not source files to stage.

Prerequisite: install the existing same-tree i2c-qcom-cci module (strip debug),
under `/lib/modules/$(uname -r)/updates/cerro-camera-identify-c1`, depmod and
modprobe. Never extract a top-level `lib` archive over `/`. Modprobe initially
exposes all three previously enabled CCI controllers, but Cerro GPIO13 is a
main-sensor power switch rather than CCI1 SCL. Before the ID probe, verify that
CCI1 has **no I2C clients**, release its platform driver with the guarded
`release-empty-cci1-and-probe.sh`, and explicitly probe the existing 4-0010.
The guarded script resolves adapter/client ownership from actual OF paths.
Use --release-only before applying the overlay.

The chip is read at Linux 7-bit address0x10, register0x0016, two big-endian
bytes. The Cerro CamX blobs plus original SlaveInformation schema specify
8-bit write address0x20, word address/data, expected0x0800/0x0906; this phone
returned **0x0800 (IMX800)**. The FP5 project's address0x1a is not applicable.

The factory sequence is preserved: AF L3M2.8V → GPIO13 → digital L1M1.104V →
IO L5M1.8V → analog L7M2.96V → MCLK1 24MHz → resetGPIO15 release. This enables
only the lens supply as required by the factory sensor power sequence; no
actuator/OIS commands are sent. Regulator voltages and clock rate are checked
on the execution path; any error unwinds all owned votes. After ID read,
reset is asserted, GPIO13 off, clocks off, and regulator use counts0. The GPIO
descriptors remain owned by the bound one-shot driver until reboot.

There is deliberately no module_exit: do not force-rmmod or remove/reapply the
overlay. A normal reboot clears the runtime-only experiment. Later sensor
integration replaces it with normal runtime-PM ownership.

Evidence and follow-on work: `notes/features/20261110-camera-imx800.md`.

Lifecycle correction: the temporary `rails[]` array uses synchronous
`regulator_bulk_get/free`, not devm, because devres outlives the probe stack.
The original version faulted during driver unbind; do not reuse its module.
The current source passed a fresh probe + explicit unbind on boot8d156fef;
zero camera power/clock votes were verified after native-driver handoff.
