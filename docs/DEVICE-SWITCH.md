# Device-local Android / Linux switch apps

Build-only checkpoint requested by the owner: APK and Linux installer archive
have been compiled/packaged; neither app has been installed/run/tested on the phone.
The already-tested computer-side swap tool remains a separate implementation
checkpoint. Do not describe the new apps as tested because the PC tool works.

See [full instructions](../tools/cerro-dualboot/device/README.md).

```sh
tools/cerro-dualboot/device/build-apps.sh
```

Outputs: `build/system-switch-apps/cerro-system-switch-android-v2.apk`,
`cerro-system-switch-linux-v2.tar.gz`, `SHA256SUMS`.

Android reads the user's `linuxkernel/*.img` directory using root and accepts
only valid complete Cerro Linux boot images. Both apps use the exact same
backend, retain the active slot and swap only boot/dtbo. Four original images,
per-slot names/scene labels/SHA and atomic progress state are retained privately
on the Linux rootfs. Linux can validate/import a prior host-side swap manifest.
No firmware, device state, image, credential or signing key is in Git.
