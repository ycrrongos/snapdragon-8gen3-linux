# Hardware status and next work

2026-11-10, tested board: Nubia Z60 Ultra / NX721J / cerro / SM8650.

The owner confirms the main camera is now basically usable. Measured main
camera behavior: factory mode1 4096×3072 RGGB RAW10; soft ISP 4088×3072 RGB at
30fps; real lens movement and contrast autofocus; manual exposure/gain and
exposure compensation controls; full-resolution JPEG and1–4× digital crop.
The Android main-camera RAW/DNG reference resolved a wrong Bayer declaration;
changing the sensor's media-bus CFA fixed red/blue inversion. Digital crop is
not optical zoom, and autofocus travel is not zoom.

The first real cold-start graph was ready at28.452s through normal multi-user
startup, with CAMCC/sensor/lens/board/CCI dependencies before CAMSS's first
probe. Actual full-resolution GUI photos and normal release were checked;
no login-time rebind/restart, timer or service masking is the integration path.
The recorded boot remained stable beyond574s, with cellular restart count0
and HiFi output present. Release does not contain the device's captured images
or private calibration. The old DP6 Image was retained during module bring-up.

Still missing: standard libcamera autofocus controls and a polished existing
Linux UI, front/ultrawide/tele cameras, optical switching, sensor-specific
CCM/LSC, OIS, denoising and Android-like low-light/automatic-exposure behavior.
Low-contrast focus can select an endpoint; far-scene sharpness was not accepted.

User's updated queue: publish source → Waydroid kernel support → front camera
and two additional rear cameras plus remaining camera quality work → accelerometer.
Dual SIM SMS/data and display are preserved regression baselines. No calls are
part of this task. Do not restart completed subsystems merely to improve logs.

For another device, none of the Cerro GPIO/power sequences, lens limits or
firmware assumptions are transferable without board-specific verification.
