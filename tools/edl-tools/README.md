# ArtistAOSP / Nubia Z60 Ultra (caza) — Qualcomm 9008 EDL 工具

工具目录：`/mnt/data/ArtistAOSP/edl-tools`

## 已安装

| 组件 | 路径 |
|------|------|
| bkerler/edl | `edl/` + `venv/` |
| Firehose (v1，Z60 Ultra) | `nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf` |
| Firehose (v2，平板等，勿用于 Z60) | `…_v2_ddr.elf` |
| 工程 ABL | `nubia_sm8650_eng/eng_v1/` |
| 本机备份镜像 | `/mnt/data/ArtistAOSP/backups/device-dump-20260717-222750/by-name/` |
| 编译产物 | `/tmp/caza-imgs/`（若还在） |

**Z60 Ultra / NX721J 只用 `sm8650_v1`，用错 v2 可能变砖。**

## 重要：memorydump ≠ 9008

| USB ID | 含义 |
|--------|------|
| `19d2:0112` | ZTE memorydump / QUSB_BULK（内核崩了），**不能**当 9008 刷 |
| `05c6:9008` | 真正的 EDL，才能用下面脚本 |

### 进 9008

1. 长按电源 20–30 秒强制关机（屏幕全黑）
2. **同时按住音量 + 和音量 −**，插入 USB（或边按边插）
3. 电脑上 `lsusb` 应出现 `05c6:9008`
4. 若一直是 `19d2:0112`，再试强制关机后重复；必要时换线/口

## 用法

```bash
# 环境
source /mnt/data/ArtistAOSP/edl-tools/edl-env.sh

# 等进 9008 后自动刷启动链（优先用 /tmp/caza-imgs 原版 vendor_boot）
./wait-9008.sh ./restore-bootchain.sh built

# 或用上次能开机的备份分区
./wait-9008.sh ./restore-bootchain.sh backup

# 手动
python3 edl/edl.py printgpt --loader=nubia_sm8650_eng/prog_ufs_firehose_sm8650_v1_ddr.elf
python3 edl/edl.py w vendor_boot_a /tmp/caza-imgs/vendor_boot.img --loader=...
python3 edl/edl.py reset --loader=...
```

`restore-bootchain.sh` 会刷 a/b：`vendor_boot`、`boot`、`init_boot`、`dtbo`、`recovery`、`vbmeta`、`vbmeta_system`（先修掉导致 panic 的 debug vendor_boot）。

## udev

已跑过 `install-udev.sh`。若权限不够：

```bash
sudo ./install-udev.sh
```
