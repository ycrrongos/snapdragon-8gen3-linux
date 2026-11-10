#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Install files only. Does not launch the GUI/backend or write partitions.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${DESTDIR:-}
prefix=$root/usr/local
install -d "$prefix/libexec/cerro-switch" "$prefix/bin" "$prefix/share/applications" "$root/usr/share/polkit-1/actions"
install -m755 "$base/switch-backend.sh" "$base/import-host-state.py" "$base/linux/system-switch.py" "$prefix/libexec/cerro-switch/"
install -m644 "$base/linux/org.cerro.SystemSwitch.desktop" "$prefix/share/applications/"
install -m644 "$base/linux/org.cerro.same-slot-switch.policy" "$root/usr/share/polkit-1/actions/"
cat > "$prefix/bin/cerro-system-switch" <<'EOF'
#!/bin/sh
exec python3 /usr/local/libexec/cerro-switch/system-switch.py "$@"
EOF
chmod 755 "$prefix/bin/cerro-system-switch"
printf '%s\n' '应用文件已安装；没有启动应用、测试切换或改写分区。需要 python3-gi、gir1.2-gtk-3.0、pkexec。'
