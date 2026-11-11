#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Install a desktop-triggered confirmation. Does not mark the current boot here.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${DESTDIR:-}
install -d "$root/usr/local/libexec/cerro-switch" "$root/usr/share/polkit-1/actions" \
 "$root/usr/lib/systemd/user" "$root/etc/systemd/user/plasma-workspace.target.wants"
install -m755 "$base/linux/desktop-boot-success.py" "$root/usr/local/libexec/cerro-switch/"
install -m644 "$base/linux/org.cerro.desktop-boot-success.policy" "$root/usr/share/polkit-1/actions/"
install -m644 "$base/linux/cerro-desktop-boot-success.service" "$root/usr/lib/systemd/user/"
ln -sfn /usr/lib/systemd/user/cerro-desktop-boot-success.service \
 "$root/etc/systemd/user/plasma-workspace.target.wants/cerro-desktop-boot-success.service"
printf '%s\n' '桌面启动成功确认已安装；下次 Plasma 会话就绪后生效，安装过程不写启动元数据。'
