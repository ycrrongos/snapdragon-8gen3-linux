# 电脑端 Android / Linux 互切

从项目根目录执行，手机 USB 接电脑：

```bash
tools/cerro-dualboot/host/switch-to-linux.sh
tools/cerro-dualboot/host/switch-to-android.sh
python3 tools/cerro-dualboot/host/switch-system.py status
```

`--dry-run` 只读核对并显示计划，不写分区。多个设备时可传 `--serial ADB_SERIAL`。
Android 需要可用的 `adb root`；Linux 通过项目的 Cerro ACM 控制台和 sudo
执行，电脑需要 Python3 + pyserial。无需手机上点选，也不依赖当前 Wi-Fi IP。

严格保持当前活动槽，不执行 set_active：

1. 切 Linux：先在电脑完整备份两槽 boot/dtbo，校验长度/SHA256，并记录原现场；
   然后把活动槽的安卓 boot/dtbo 复制到非活动槽，对复制结果逐个算 SHA256。
2. 将活动槽 dtbo **全分区清零**，写入 Linux boot；两者读回校验完成后才重启。
3. 切 Android：核对手机 rootfs UUID、槽位、保存的状态及非活动槽两个安卓镜像
   的完整 SHA256，再复制回同一活动槽并逐个校验，最后重启。

默认 Linux 镜像是已验证 Waydroid C1 daily（96MiB，SHA18886d05…，保留DP6显示），不重新构建内核。
换镜像必须显式提供 `--linux-boot PATH --linux-sha256 FULL_SHA256`。
除 boot/dtbo 外不写任何分区，不动 GPT 活动槽、vendor_boot、init_boot、vbmeta、
recovery、super、userdata、ABL/XBL。Linux rootfs 位于独立 cerro_linux 分区。

电脑备份和每步状态在 `backups/dualboot-swap/<serial>/`（不提交 Git）。每轮都有
带 `slot_a`/`slot_b` 的目录、现场 LABEL、SHA256SUMS 和 before/observed JSON。
保留整个目录，切回 Android 会用其中的清单核对手机上的缓存；原非活动槽被
覆盖前也已完整备份。新一次 Android→Linux 仍会备份当前 Android，适用于更新后。

重复切 Linux 不会把 Linux 镜像复制成安卓备份。写入/校验失败会立即停止，不重启；
若只进行到准备的一半且 Android 仍在运行，执行切 Android 可以撤销已完成的准备，
前提是缓存两文件完整匹配；缓存损坏时拒绝写入。不要在失败现场手动重启或运行
旧的机内换槽脚本。完整 host 备份可用于另行核实后的 fastboot 恢复。

重启后自动观察最多510秒，交叉核对新 boot_id、同一槽位和镜像 SHA；Android
还需 boot_completed=1。超时只记“启动未确认”，不自动换槽或回刷镜像。
Linux 观察只证明此镜像可启动，不能据此宣称所有硬件功能通过。

本地故障检查：

```bash
python3 tools/cerro-dualboot/host/test_switch_system.py
```
