# Cerro camera optics audit and bounded experiments

This is diagnostic support, not a completed daily autofocus implementation.
The current raw image path uses factory IMX800 mode7, and actual AK7316 lens
motion now resolves the gross defocus. Colour calibration, zoom, other cameras,
normal V4L2/libcamera AF and cold-start integration are still open.

The exact AuroraAOSP Cerro reference is the local ArtistAOSP source tree:
`kernel/nubia/sm8650-devicetrees/qcom/camera/zte-pineapple-camera-sensor-cerro.dtsi`,
`device/nubia/cerro/{extract-files.py,proprietary-files.txt}`, and its vendor
sensormodule/tuned/EEPROM/OIS libraries. The device tree points at sensor,
actuator, OIS and EEPROM separately; CamX supplies per-device commands and
algorithms. Installing a camera APK or copying DTS alone cannot supply them to
native mainline V4L2. No vendor blobs are redistributed here.

`audit-factory.py` requires the exact known sensor blob hash and checks packed
root/leaf fields against the published CamX schemas. It establishes AK7316 at
CCI0 master1/7-bit0x0c, 10-bit position register0 shifted6, mode register2
standby0x40/active0, and EEPROM0x55 with calibrated macro/infinity at13/15 BIG.
`read-calibration.py` reads only those known devices while the sensor is powered;
private EEPROM contents remain on the phone (0600). This unit's endpoints are
<per-unit-focus>..<per-unit-focus>. Do not reuse them on a different unit without reading its calibration.

`focus-sweep.py` owns a bounded continuous raw stream, measures an unchanged
exposure, moves only within that unit's OTP bounds, verifies position readback,
compares central same-colour gradients, and parks/standbys before STREAMOFF.
The first fixed bookshelf test found144 and repeated it: score1.19185 versus
0.05047 at940; actual image sharpness changed. This proves focus control, not
continuous autofocus or final colour quality.

References (interface facts only):
- [CamX actuator schema](https://github.com/comprehensive9/vendor_qcom_proprietary/blob/11se/chi-cdk/api/sensor/camxactuatordriver.xsd)
- [CamX EEPROM schema](https://github.com/comprehensive9/vendor_qcom_proprietary/blob/11se/chi-cdk/api/sensor/camxeepromdriver.xsd)
- [Mainline AK73xx V4L2 lens driver](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/ak7375.c)
- [libcamera softISP AF work](https://patchwork.libcamera.org/cover/28725/) explicitly notes missing focus stats; it is not a finished phone AF stack.

The standard lens prototype is `ak7316-cerro.c` and
`camera-lens-overlay.dts`. It exposes FOCUS_ABSOLUTE with this unit's112..<per-unit-focus>
OTP range, shares only the real L3M supply, uses runtime PM on open/close,
and parks before standby. The tested C implementation requires1ms between
standby/active writes, as in the successful Python experiment;1–10us NACKed.
Module96486fab… was tested through `focus-sweep.py --v4l2`, reproducing best144
and actual image focus. Overlay a1c5c1f9…/supply344 is runtime-only and
`install-lens-runtime.sh` rejects mismatched live supply/OTP or a second apply.
A normal board DT/NVMEM calibration provider is still required for a portable
cold-start setup. qcam0.4 captured focused30fps but its stop queue asserted once;
that userspace defect is recorded and remains open, despite correct rail release.
