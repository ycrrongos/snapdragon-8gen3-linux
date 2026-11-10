# RM692H0 显示源码恢复（2026-10-31）

状态：候选 disp-r1 已编译，实机验收进行中。内核树 commit `52fa4bbc4`。

用户指定资源：旧 Cursor 备份、Aurora Cerro 设备树、显示正常的旧 boot/内核。历史 PenguinOS/ArtistAOSP 按用户说明指 Aurora 参考树；当前主屏 BF068/RM692H0。

## 已证实的重建错误

- ACTIVE_LOW reset 必须 0/1/0，结束释放（7f8c3d7b L137）。
- s5bt 正向亮度 3515 才是用户确认点亮的版本（L1021/L1027），反相 DBV 是失败的中间实验。
- 常量区不是命令流。好内核 `rm692h0_on` 0xb6e738..0xb77630 有 243 处 typed 消息提交：242 常量包 + 1 动态 BD。原重建“339 写”是错误切分。
- 从历史源码恢复的 242 包，其 dtype 和变长 payload 多重集与二进制一致。前 12 个长写（0x39）不能改成短写（0x15）。
- DSC ALL_SLICES 标志恢复 BIT(8)，避免与 HS_PKT_END_ALIGNED BIT(12) 撞位。

## 可复现恢复

`python3 tools/recover-cerro-panel-history.py rong-important-backup-20261013-231723.zip build/recovered-on.c`

脚本只解析历史 JSONL 字符串，不执行历史 shell 命令。以 s5bc 完整函数为起点，重放后续匹配的 StrReplace，接回 s5ew 动态刷新前缀与 BD 修复。结果与本目录 panel 源码的 on() 一致。

本目录保留完整 panel 源码和相对内核事故快照 `a8cccd207` 的 host/Kconfig/Makefile 补丁；不要覆盖已有未提交文件。源码同时已提交内核树。好内核 blob 仍在 backups，主仓库不收二进制。
