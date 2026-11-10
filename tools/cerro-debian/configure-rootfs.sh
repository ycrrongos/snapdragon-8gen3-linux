#!/bin/sh
# Configure a debootstrap-created Debian root as the native Cerro userspace.
# Run as root on the phone while the working postmarketOS system is active.
set -eu

DEBIAN_ROOT=${1:-/debian-root}
KERNEL_RELEASE=$(uname -r)
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TOOLS_DIR=$(dirname "$SCRIPT_DIR")

if [ "$(id -u)" != 0 ]; then
  echo "configure-rootfs: run as root" >&2
  exit 1
fi
if [ ! -x "$DEBIAN_ROOT/bin/bash" ] || [ ! -f "$DEBIAN_ROOT/etc/debian_version" ]; then
  echo "configure-rootfs: $DEBIAN_ROOT is not a completed Debian root" >&2
  exit 1
fi

echo "configure-rootfs: root=$DEBIAN_ROOT kernel=$KERNEL_RELEASE"

mkdir -p "$DEBIAN_ROOT/dev" "$DEBIAN_ROOT/proc" "$DEBIAN_ROOT/sys" "$DEBIAN_ROOT/run"
if ! mountpoint -q "$DEBIAN_ROOT/dev"; then
  mount --rbind /dev "$DEBIAN_ROOT/dev"
  mount --make-rslave "$DEBIAN_ROOT/dev"
fi
if ! mountpoint -q "$DEBIAN_ROOT/proc"; then
  mount -t proc proc "$DEBIAN_ROOT/proc"
fi
if ! mountpoint -q "$DEBIAN_ROOT/sys"; then
  mount --rbind /sys "$DEBIAN_ROOT/sys"
  mount --make-rslave "$DEBIAN_ROOT/sys"
fi
if ! mountpoint -q "$DEBIAN_ROOT/run"; then
  mount --rbind /run "$DEBIAN_ROOT/run"
  mount --make-rslave "$DEBIAN_ROOT/run"
fi

rm -f "$DEBIAN_ROOT/etc/resolv.conf"
cp -a /etc/resolv.conf "$DEBIAN_ROOT/etc/resolv.conf"

cat >"$DEBIAN_ROOT/etc/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/debian
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/debian-security
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
rm -f "$DEBIAN_ROOT/etc/apt/sources.list"

cat >"$DEBIAN_ROOT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 755 "$DEBIAN_ROOT/usr/sbin/policy-rc.d"

chroot "$DEBIAN_ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  apt-get update
chroot "$DEBIAN_ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  apt-get -y install \
    systemd-sysv udev dbus sudo locales console-setup \
    network-manager wpasupplicant wireless-regdb bluez rfkill \
    kmod pciutils usbutils iputils-ping wget alsa-utils alsa-ucm-conf qbootctl \
    modemmanager libqmi-utils qrtr-tools rmtfs tqftpserv protection-domain-mapper python3 \
    pipewire-audio wireplumber \
    task-kde-desktop firefox-esr \
    xserver-xorg-input-libinput libinput-tools mesa-utils

for OPTIONAL_PACKAGE in \
  maliit-keyboard mesa-vulkan-drivers \
  libspa-0.2-bluetooth firmware-qcom-soc firmware-atheros; do
  OPTIONAL_CANDIDATE=$(chroot "$DEBIAN_ROOT" apt-cache policy "$OPTIONAL_PACKAGE" 2>/dev/null | \
    awk '/Candidate:/ { print $2; exit }')
  if [ -n "$OPTIONAL_CANDIDATE" ] && [ "$OPTIONAL_CANDIDATE" != "(none)" ]; then
    chroot "$DEBIAN_ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
      apt-get -y install "$OPTIONAL_PACKAGE"
  else
    echo "configure-rootfs: optional package unavailable: $OPTIONAL_PACKAGE"
  fi
done

printf '%s\n' 'zh_CN.UTF-8 UTF-8' 'en_US.UTF-8 UTF-8' >"$DEBIAN_ROOT/etc/locale.gen"
chroot "$DEBIAN_ROOT" locale-gen
printf '%s\n' 'LANG=zh_CN.UTF-8' >"$DEBIAN_ROOT/etc/default/locale"
ln -sfn /usr/share/zoneinfo/Australia/Perth "$DEBIAN_ROOT/etc/localtime"
printf '%s\n' 'Australia/Perth' >"$DEBIAN_ROOT/etc/timezone"
printf '%s\n' 'nubia-cerro' >"$DEBIAN_ROOT/etc/hostname"
cat >"$DEBIAN_ROOT/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 nubia-cerro
::1 localhost ip6-localhost ip6-loopback
EOF
cat >"$DEBIAN_ROOT/etc/fstab" <<'EOF'
# The embedded Cerro initramfs mounts /dev/sda12 and bind-mounts /debian-root
# as the native root before starting Debian systemd.
proc /proc proc nosuid,nodev,noexec 0 0
EOF

if ! chroot "$DEBIAN_ROOT" id user >/dev/null 2>&1; then
  chroot "$DEBIAN_ROOT" useradd -m -s /bin/bash user
fi
chroot "$DEBIAN_ROOT" usermod -aG sudo,audio,video,input,render,netdev,bluetooth,dialout user
printf '%s\n' 'user:user' | chroot "$DEBIAN_ROOT" chpasswd
chroot "$DEBIAN_ROOT" passwd -l root >/dev/null

# Carry the already validated custom kernel modules and firmware into Debian.
mkdir -p "$DEBIAN_ROOT/lib/modules" "$DEBIAN_ROOT/lib/firmware"
rm -rf "$DEBIAN_ROOT/lib/modules/$KERNEL_RELEASE"
cp -a "/lib/modules/$KERNEL_RELEASE" "$DEBIAN_ROOT/lib/modules/"
for FIRMWARE_TREE in ath12k qca qcom; do
  if [ -e "/lib/firmware/$FIRMWARE_TREE" ]; then
    rm -rf "$DEBIAN_ROOT/lib/firmware/$FIRMWARE_TREE"
    cp -a "/lib/firmware/$FIRMWARE_TREE" "$DEBIAN_ROOT/lib/firmware/"
  fi
done
for FIRMWARE_FILE in \
  /lib/firmware/aw882xx_acf.bin /lib/firmware/aw_cali.bin \
  /lib/firmware/regulatory.db /lib/firmware/regulatory.db.p7s; do
  [ -e "$FIRMWARE_FILE" ] && cp -a "$FIRMWARE_FILE" "$DEBIAN_ROOT/lib/firmware/"
done
chroot "$DEBIAN_ROOT" depmod -a "$KERNEL_RELEASE"

# Reuse the Cerro services already validated under the same kernel.
mkdir -p "$DEBIAN_ROOT/usr/local/sbin" "$DEBIAN_ROOT/etc/systemd/system"
for CERRO_SCRIPT in /usr/local/sbin/cerro-*.sh; do
  [ -f "$CERRO_SCRIPT" ] && cp -a "$CERRO_SCRIPT" "$DEBIAN_ROOT/usr/local/sbin/"
done
for CERRO_UNIT in /etc/systemd/system/cerro-*.service; do
  [ -f "$CERRO_UNIT" ] && cp -a "$CERRO_UNIT" "$DEBIAN_ROOT/etc/systemd/system/"
done

# Install the project-audited early DMS handoff and identifier-safe UIM setup.
# These files are only staged into the new root; configure-rootfs does not boot
# the root or start either oneshot service.
for REQUIRED_CELLULAR_SOURCE in \
  cerro-cellular-meta.sh cerro-qmi-dms-set-meta.py \
  cerro-cellular-meta.service cerro-cellular-prepare.sh \
  cerro-cellular-prepare.service cerro-modemmanager-order.conf \
  cerro-pdmap-stage.sh cerro-pdmap-stage.service \
  cerro-pdmap-stage-order.conf; do
  if [ ! -f "$TOOLS_DIR/$REQUIRED_CELLULAR_SOURCE" ]; then
    echo "configure-rootfs: missing $TOOLS_DIR/$REQUIRED_CELLULAR_SOURCE" >&2
    exit 1
  fi
done
mkdir -p \
  "$DEBIAN_ROOT/usr/local/sbin" \
  "$DEBIAN_ROOT/usr/local/libexec" \
  "$DEBIAN_ROOT/etc/systemd/system/ModemManager.service.d" \
  "$DEBIAN_ROOT/etc/systemd/system/pd-mapper.service.d"
install -m 0755 "$TOOLS_DIR/cerro-cellular-meta.sh" \
  "$DEBIAN_ROOT/usr/local/sbin/cerro-cellular-meta.sh"
install -m 0755 "$TOOLS_DIR/cerro-qmi-dms-set-meta.py" \
  "$DEBIAN_ROOT/usr/local/libexec/cerro-qmi-dms-set-meta.py"
install -m 0644 "$TOOLS_DIR/cerro-cellular-meta.service" \
  "$DEBIAN_ROOT/etc/systemd/system/cerro-cellular-meta.service"
install -m 0755 "$TOOLS_DIR/cerro-cellular-prepare.sh" \
  "$DEBIAN_ROOT/usr/local/sbin/cerro-cellular-prepare.sh"
install -m 0644 "$TOOLS_DIR/cerro-cellular-prepare.service" \
  "$DEBIAN_ROOT/etc/systemd/system/cerro-cellular-prepare.service"
install -m 0644 "$TOOLS_DIR/cerro-modemmanager-order.conf" \
  "$DEBIAN_ROOT/etc/systemd/system/ModemManager.service.d/cerro-cellular-order.conf"
install -m 0755 "$TOOLS_DIR/cerro-pdmap-stage.sh" \
  "$DEBIAN_ROOT/usr/local/sbin/cerro-pdmap-stage.sh"
install -m 0644 "$TOOLS_DIR/cerro-pdmap-stage.service" \
  "$DEBIAN_ROOT/etc/systemd/system/cerro-pdmap-stage.service"
install -m 0644 "$TOOLS_DIR/cerro-pdmap-stage-order.conf" \
  "$DEBIAN_ROOT/etc/systemd/system/pd-mapper.service.d/zz-cerro-pdmap-stage.conf"

# Bind the q6v5 devices before pd-mapper scans their protection-domain maps.
# Starting the module only from rmtfs ExecStartPre races pd-mapper: a mapper
# failure can cancel modprobe mid-probe and leave both MPSS and ADSP unbound.
mkdir -p \
  "$DEBIAN_ROOT/etc/systemd/system/multi-user.target.wants" \
  "$DEBIAN_ROOT/etc/systemd/system/pd-mapper.service.d" \
  "$DEBIAN_ROOT/etc/systemd/system/rmtfs.service.d"
cat >"$DEBIAN_ROOT/etc/systemd/system/cerro-remoteproc-prepare.service" <<'EOF'
[Unit]
Description=Cerro remoteproc drivers before PD mapper and modem startup
After=local-fs.target systemd-modules-load.service
Before=pd-mapper.service rmtfs.service cerro-audio.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/modprobe rmtfs_mem
ExecStart=/sbin/modprobe qcom-memshare
ExecStart=/sbin/modprobe qcom_q6v5_pas
ExecStart=/sbin/modprobe ipa
ExecStart=/sbin/modprobe qrtr_smd
ExecStart=/sbin/modprobe rmnet

[Install]
WantedBy=multi-user.target
EOF
cat >"$DEBIAN_ROOT/etc/systemd/system/pd-mapper.service.d/cerro-remoteproc-order.conf" <<'EOF'
[Unit]
Requires=cerro-remoteproc-prepare.service
After=cerro-remoteproc-prepare.service
EOF
cat >"$DEBIAN_ROOT/etc/systemd/system/rmtfs.service.d/zz-cerro-writable.conf" <<'EOF'
[Unit]
Requires=cerro-remoteproc-prepare.service tqftpserv.service pd-mapper.service
After=local-fs.target systemd-modules-load.service cerro-remoteproc-prepare.service tqftpserv.service pd-mapper.service

[Service]
ExecStartPre=-/sbin/modprobe rmtfs_mem
ExecStartPre=-/sbin/modprobe qcom-memshare
ExecStartPre=-/sbin/modprobe qcom_q6v5_pas
ExecStartPre=-/sbin/modprobe ipa
ExecStartPre=-/sbin/modprobe qrtr_smd
ExecStartPre=-/sbin/modprobe rmnet
ExecStart=
ExecStart=/usr/bin/rmtfs -P -s
EOF
ln -sfn /etc/systemd/system/cerro-remoteproc-prepare.service \
  "$DEBIAN_ROOT/etc/systemd/system/multi-user.target.wants/cerro-remoteproc-prepare.service"

# qbootctl's stock first-boot unit can run before the UFS partition symlinks
# exist on this phone.  Delay it and require consistent current/active slots.
if [ -f /usr/local/sbin/cerro-qboot-mark-success.sh ]; then
  cp -a /usr/local/sbin/cerro-qboot-mark-success.sh \
    "$DEBIAN_ROOT/usr/local/sbin/cerro-qboot-mark-success.sh"
fi
if [ -f /etc/systemd/system/qbootctl.service.d/debian-native.conf ]; then
  mkdir -p "$DEBIAN_ROOT/etc/systemd/system/qbootctl.service.d"
  cp -a /etc/systemd/system/qbootctl.service.d/debian-native.conf \
    "$DEBIAN_ROOT/etc/systemd/system/qbootctl.service.d/debian-native.conf"
fi

# Audio UCM and per-user speaker sink helper.
mkdir -p \
  "$DEBIAN_ROOT/usr/share/alsa/ucm2/Qualcomm/sm8650/CERRO" \
  "$DEBIAN_ROOT/usr/share/alsa/ucm2/conf.d/sm8650" \
  "$DEBIAN_ROOT/usr/lib/systemd/user" \
  "$DEBIAN_ROOT/etc/systemd/user/default.target.wants" \
  "$DEBIAN_ROOT/etc/xdg/autostart"
if [ -d /usr/share/alsa/ucm2/Qualcomm/sm8650/CERRO ]; then
  cp -a /usr/share/alsa/ucm2/Qualcomm/sm8650/CERRO/. \
    "$DEBIAN_ROOT/usr/share/alsa/ucm2/Qualcomm/sm8650/CERRO/"
fi
ln -sfn ../../Qualcomm/sm8650/CERRO/SM8650-CERRO.conf \
  "$DEBIAN_ROOT/usr/share/alsa/ucm2/conf.d/sm8650/SM8650-CERRO.conf"
if [ -f /usr/lib/systemd/user/cerro-audio-session.service ]; then
  cp -a /usr/lib/systemd/user/cerro-audio-session.service \
    "$DEBIAN_ROOT/usr/lib/systemd/user/"
  ln -sfn /usr/lib/systemd/user/cerro-audio-session.service \
    "$DEBIAN_ROOT/etc/systemd/user/default.target.wants/cerro-audio-session.service"
fi
if [ -f /etc/xdg/autostart/cerro-audio-session.desktop ]; then
  cp -a /etc/xdg/autostart/cerro-audio-session.desktop \
    "$DEBIAN_ROOT/etc/xdg/autostart/"
fi

# Preserve the working Wi-Fi profile without printing its credentials.
mkdir -p "$DEBIAN_ROOT/etc/NetworkManager/system-connections"
for NM_PROFILE in /etc/NetworkManager/system-connections/*; do
  [ -f "$NM_PROFILE" ] || continue
  cp -a "$NM_PROFILE" "$DEBIAN_ROOT/etc/NetworkManager/system-connections/"
done
# pmOS used the legacy wlan0 name; Debian's predictable PCI name is wlp1s0.
# Keep all secrets untouched and only repair this exact interface binding.
for NM_PROFILE in "$DEBIAN_ROOT/etc/NetworkManager/system-connections/"*; do
  [ -f "$NM_PROFILE" ] || continue
  sed -i 's/^interface-name=wlan0$/interface-name=wlp1s0/' "$NM_PROFILE"
done
chmod 700 "$DEBIAN_ROOT/etc/NetworkManager/system-connections"
chmod 600 "$DEBIAN_ROOT/etc/NetworkManager/system-connections/"* 2>/dev/null || true

# Debian's native glibc qbootctl prevents A/B retry exhaustion. Do not copy the
# postmarketOS binary: it uses /lib/ld-musl-aarch64.so.1 and cannot run here.
if [ -x "$DEBIAN_ROOT/usr/bin/qbootctl" ] && [ -f /usr/lib/systemd/system/qbootctl.service ]; then
  mkdir -p "$DEBIAN_ROOT/usr/lib/systemd/system"
  cp -a /usr/lib/systemd/system/qbootctl.service "$DEBIAN_ROOT/usr/lib/systemd/system/"
fi

mkdir -p \
  "$DEBIAN_ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d" \
  "$DEBIAN_ROOT/etc/systemd/logind.conf.d" \
  "$DEBIAN_ROOT/etc/sddm.conf.d"
cat >"$DEBIAN_ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d/cerro.conf" <<'EOF'
[Unit]
After=cerro-usb-acm.service
Requires=cerro-usb-acm.service
EOF
cat >"$DEBIAN_ROOT/etc/systemd/logind.conf.d/cerro-bringup.conf" <<'EOF'
[Login]
IdleAction=ignore
HandlePowerKey=ignore
EOF
cat >"$DEBIAN_ROOT/etc/systemd/system/cerro-nosleep.service" <<'EOF'
[Unit]
Description=Cerro bring-up: block KDE/system sleep and keep USB ACM alive
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/systemd-inhibit --what=idle:sleep --who=cerro-bringup --why=keep-USB-ACM-and-install-jobs-alive --mode=block /bin/sleep infinity
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$DEBIAN_ROOT/home/user/.config"
cat >"$DEBIAN_ROOT/home/user/.config/powerdevilrc" <<'EOF'
[AC][SuspendSession]
idleTime=0
suspendType=0

[Battery][SuspendSession]
idleTime=0
suspendType=0

[LowBattery][SuspendSession]
idleTime=0
suspendType=0
EOF
cat >"$DEBIAN_ROOT/home/user/.config/kwinrc" <<'EOF'
[Wayland]
InputMethod=/usr/share/applications/com.github.maliit.keyboard.desktop
EOF
chroot "$DEBIAN_ROOT" chown -R user:user /home/user/.config

PLASMA_SESSION=plasma.desktop
if [ ! -f "$DEBIAN_ROOT/usr/share/wayland-sessions/$PLASMA_SESSION" ]; then
  PLASMA_SESSION=plasmawayland.desktop
fi
cat >"$DEBIAN_ROOT/etc/sddm.conf.d/cerro.conf" <<EOF
[Autologin]
User=user
Session=$PLASMA_SESSION
Relogin=true

[General]
DisplayServer=wayland
EOF

# Native pre-systemd init used after switch_root into the Debian mountpoint.
cat >"$DEBIAN_ROOT/cerro-sd-prep" <<'EOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /dev/pts /run /tmp /sys/fs/cgroup /run/systemd /var/tmp /sys/kernel/config
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sysfs /sys
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mountpoint -q /run || mount -t tmpfs -o mode=755,nodev,nosuid,strictatime tmpfs /run
mountpoint -q /tmp || mount -t tmpfs tmpfs /tmp
mountpoint -q /sys/kernel/config || mount -t configfs configfs /sys/kernel/config 2>/dev/null || true
mountpoint -q /sys/fs/cgroup || mount -t cgroup2 -o nsdelegate cgroup2 /sys/fs/cgroup 2>/dev/null || true
echo 0 >/sys/class/graphics/fb0/blank 2>/dev/null || true
printf '\033[2J\033[HNative Debian 13 (trixie) on Nubia Z60 Ultra\n' >/dev/tty1 2>/dev/null || true
[ -x /usr/local/sbin/cerro-usb-acm.sh ] && /usr/local/sbin/cerro-usb-acm.sh >/dev/kmsg 2>&1 || true
exec /lib/systemd/systemd --system
EOF
chmod 755 "$DEBIAN_ROOT/cerro-sd-prep"

chroot "$DEBIAN_ROOT" systemctl enable \
  NetworkManager.service bluetooth.service sddm.service \
  serial-getty@ttyGS0.service getty@tty1.service \
  cerro-usb-acm.service cerro-usbnet.service \
  cerro-wifi.service cerro-bt.service cerro-audio.service \
  cerro-nosleep.service cerro-remoteproc-prepare.service cerro-pdmap-stage.service \
  tqftpserv.service pd-mapper.service rmtfs.service \
  cerro-cellular-meta.service cerro-cellular-prepare.service \
  ModemManager.service
chroot "$DEBIAN_ROOT" systemctl mask \
  sleep.target suspend.target hibernate.target hybrid-sleep.target \
  suspend-then-hibernate.target
if [ -f "$DEBIAN_ROOT/usr/lib/systemd/system/qbootctl.service" ]; then
  chroot "$DEBIAN_ROOT" systemctl enable qbootctl.service
fi

rm -f "$DEBIAN_ROOT/usr/sbin/policy-rc.d"
rm -f "$DEBIAN_ROOT/etc/machine-id"
chroot "$DEBIAN_ROOT" systemd-machine-id-setup
touch "$DEBIAN_ROOT/.cerro-native-debian"
chroot "$DEBIAN_ROOT" apt-get clean
sync

echo "configure-rootfs: native Debian root is ready at $DEBIAN_ROOT"
