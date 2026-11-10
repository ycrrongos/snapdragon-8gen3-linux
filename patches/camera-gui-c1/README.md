# Cerro GUI camera (libcamera0.8 qcam derivative)

Uses GPL qcam with native V4L2 AK7316 controls; this is a usable main-camera
checkpoint, not Android image-quality parity or a completed multi-camera port.
The current profile is4096×3072 RAW input /4088×3072 RGB preview+JPEG.
The CPU debayer keeps4 pixels per side for interpolation. The former1024×576
request centre-cropped the input rather than scaling it; the new profile
restored almost the entire mode7 field of view. The current mode1 profile
uses2×2 binning and the full4:3 field of view;60 real RGB frames passed
at30fps, as did actual GUI autofocus, JPEG capture and normal exit.

Features tested on the phone:
- Chinese camera window, desktop launcher, capture directly to the XDG Pictures
  directory's `相机` subdirectory; JPEG95 and visible success/error feedback.
- Actual V4L2 focus motion through the calibrated112..<per-unit-focus> range, not fake UI.
  A one-shot contrast AF starts after45 actual preview frames and can be
  retriggered with the button. It compares coarse/fine positions, then returns
  to the best measured position. Manual focus slider is also provided.
- During AF, request metadata snapshots exposure/gain/colour gains; explicit
  manual modes and values hold these constant. Metadata verifies the mode
  transition. Completion restores auto modes. Simply switching AWB off would
  use default manual gains and introduce green tint: do not reintroduce it.
-1–4× centre-crop digital zoom affects both painted preview and saved image.
  It does not claim optical zoom or more detail.2× saves2044×1536 from this
  preview profile. Multi-camera optical switching and high-resolution still
  capture are separate pending work.

Reproduce using the exact0.8 archive (SHA in the feature note), apply
`patches/camera-userspace-c1/0002-libcamera-08-imx800-helper.patch`, then run
`python3 patches/camera-gui-c1/apply-gui.py LIBCAMERA_SOURCE` against fresh qcam
sources. The script writes `0001-qcam-cerro-controls.patch` and copies the two
own source files. Build with the isolated Qt/sysroot environment in
`patches/camera-userspace-c1/build-08-on-phone.sh`; install only the dedicated
`/opt/cerro-camera-0.8/bin/qcam`, wrapper and desktop entry, not system libraries.

`CERRO_CAMERA_SMOKE_TEST=1` makes the real GUI automatically focus, take a1×
photo and2× crop through the same save handler, then close normally. It needs
real hardware and a fixed textured scene; it is not a mock or a colour test.
Second smoke: real metadata manual modes confirmed, AF picked144 (same as RAW
and direct V4L2), both JPEGs created, exit0, lens+sensor suspended/four rails0.
See `notes/features/20261110-camera-imx800.md` for remaining calibration, OIS,
other-camera and cold-start work. Image quality is not signed off.

Exposure controls now expose automatic EV compensation and explicit manual
shutter/gain from the camera's advertised ranges. Changing these controls
cancels an in-progress AF measurement and returns to the user's selected
exposure mode. `CERRO_CAMERA_EXPOSURE_TEST=1` exercises four stages and saves
each through the actual JPEG handler before normal exit. Real metadata and
pixel brightness verified manual4372us/2x versus33209us/8x. The current dark
scene saturates automatic exposure at its limit, so this does not sign off
automatic EV response or the reported intermittent overexposure.
