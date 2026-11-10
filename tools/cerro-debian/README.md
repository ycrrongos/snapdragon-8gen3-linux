# Native Debian 13 on Nubia Z60 Ultra (cerro)

This path builds a complete **native** Debian arm64 system. It does not run
Debian under QEMU, a VM, a container, or chroot after boot. The working
postmarketOS userspace is used only as a safe installer and rollback root.

The final boot flow is:

```text
ABL -> Cerro mainline Image + embedded initramfs
    -> mount /dev/sda12
    -> bind-mount /debian-root as the real root mountpoint
    -> switch_root /cerro-sd-prep
    -> Debian systemd (PID 1) -> SDDM -> Plasma Wayland
```

Build the base root on the phone:

```sh
sudo debootstrap --arch=arm64 --variant=minbase trixie \
  /debian-root https://deb.debian.org/debian
```

Then copy `configure-rootfs.sh` to the phone and run it as root. It installs
the Debian desktop, creates the local user, migrates the already validated
Cerro modules/firmware/services, and prepares Debian systemd. Do not switch
the boot path until `.cerro-native-debian` exists and chroot validation passes.

Run `validate-rootfs.sh /debian-root` before flashing. It checks Debian 13
arm64 identity, dpkg/APT consistency, KDE/Wayland/Mesa, the user account,
Cerro modules/firmware/UCM, service enablement, Wi-Fi profile presence and all
permanent no-sleep masks.

The initial bring-up login is `user` / `user`, matching the existing serial
recovery login. Change it after validation.

After rootfs/chroot validation, `build-boot.sh` rebuilds only the embedded
initramfs selector and packages a header-v2 s5gb image whose cmdline contains
`cerro_userland=debian`. The original s5gb boot image remains the rollback
artifact. Flashing is deliberately a separate step so an incomplete rootfs can
never be selected accidentally.
