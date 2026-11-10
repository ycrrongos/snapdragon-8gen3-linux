# Cerro dual-boot tools

See `notes/cerro-dualboot.md` for architecture.

| Script | Where | Role |
|--------|--------|------|
| `android/switch-to-linux.sh` | Android (KernelSU `su`) | Flash Linux daily/debug boot → slot B, activate B, reboot |
| `android/switch-to-android.sh` | Android | Restore Android boot chain → slot A, reboot |
| `linux/switch-to-android.sh` | Debian | Write saved Android images / abctl → reboot Android |
| `linux/switch-to-linux-variant.sh` | Debian | Pick daily vs debug boot on slot B |
| `host/partition-plan.sh` | Host | Print GPT math for 200GiB userdata + cerro_linux |
| `recovery/do-repartition.sh` | OrangeFox adb shell | resize.f2fs + sgdisk + mkfs.ext4 |

Images live in `/data/cerro-dualboot/` (Android) and `/var/lib/cerro-dualboot/` (Linux).

## Desktop UX (Debian)

| Item | Path |
|------|------|
| Daily boot 修法 | `notes/cerro-daily-boot-fix.md` |
| 安装（登录屏 / 电源键 / 切 Android 图标） | `linux/install-desktop-ux.sh` |
| 应用列表「切换到 Android」 | `/usr/share/applications/cerro-switch-to-android.desktop` |
| 电源键守护 | `cerro-powerkey.service`：短按 = PowerDevil「Turn Off Screen」/wakeup（v2；不锁屏；禁 cerro-dpms）；长按≥3s = 电源菜单 |


