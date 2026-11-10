# Cerro Android camera reference probe

Small Camera2 diagnostic APK. Reads all enumerated CameraCharacteristics,
opens a chosen camera with ordinary preview, saves bounded JPEG/capture-result
metadata and closes camera resources. No firmware, calibration, NVM or partition
writes. Files include private scene/metadata: keep them in ignored build/logs.

Build with `bash tools/cerro-camera-reference/build.sh`. Uses installed Android35
SDK/aapt2/d8/apksigner, creates its debug key and outputs only under ignored
`build/camera-20261110/android-reference-apk/`. The main0.8 Linux GUI and rootfs
are independent from this probe. Install/permission grant on an authorized
Android session only, then launch `.MainActivity --es camera 0`. Supported intent
extras `ev` (int), `exposureUs` (long)+`iso` (int), `zoom` (float) are ordinary
Camera2 controls; consult each camera's characteristics before using them.

Actual Android reference captured on2026-11-10 after the user reinstalled
PenguinAOSP. The updated probe supports `--ez raw true` for bounded RAW_SENSOR
plus JPEG capture, saves DNG/raw16/layout and capture metadata, and inventories
logical cameras and exposed physical IDs. Rational values are serialized as
strings: Android Rational extends Number but its `1/6` spelling is not JSON.

Vendor auxiliary-camera visibility initially remapped app camera0 to the
ultrawide. With the probe temporarily added to the existing auxiliary allowlist,
logical camera4 reported activePhysicalId0 and8.29mm; kernel logs confirmed
IMX8000800. Its real4096x3072 DNG CFA isRGGB. Camera2 and3 captured actual
ultrawide and telephoto RAW/JPEG too. The allowlist was restored, camera resources
closed, and private images/calibration JSON remain only in ignored build/logs.
See the feature note for evidence and remaining Linux work. Do not infer that
any physical camera was tested merely because it appears in inventory.

[CameraCharacteristics reference](https://developer.android.com/reference/android/hardware/camera2/CameraCharacteristics)
