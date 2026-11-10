# audio-s5fy — AW88261 PLL/SYSST 诊断

## 目的

`s5fx` 已打通 `PRIMARY_MI2S_RX` 的 PCM/SET_CFG 路径，但两个 AW88261
功放仍只报告 `start failure (-1)`。该返回值可能来自 PLL/IIS 检查，也可能
来自功放解除 power-down 后的完整 SYSST 检查，旧日志无法区分。

## 改动

- `aw88261_dev_get_iis_status()`：把 PLL 失败提升到 `dev_err`，打印
  `SYSST` 实值与预期位；成功时打印实值。
- `aw88261_dev_check_sysst()`：逐次打印 `SYSST` 实值、预期位和重试次数；
  成功时打印实值。
- 不改变寄存器写入、重试次数、延迟或功放状态机。
- 内置 DTB 标签：`cerro_dtb=s5fy`。

## 产物与状态

- 镜像：`build/boot_repack/boot-v2-disp-dpu-s5fy.img`
- 诊断模块已重编，并替换进 `usr/cerro-initramfs.cpio.gz` 后重新嵌入 Image。
- 2026-08-17 13:54：经真 `05c6:9008` 双槽刷入并启动，`cerro_dtb=s5fy`。
- 48 kHz/S16_LE/双声道试播 `EXIT=0`；两颗功放均 PLL `0x0011`、
  SYSST `0x0311`、`start success`。
- 活动 `SYSCTRL=0x3240`（上电、功放开启、硬静音/ULS 静音均清），默认
  音量 -22.5 dB；临时 -7.5 dB 复测也 `EXIT=0`。物理可闻待人耳确认。
- 同状态的零 PCM / 440Hz 对照中，`ISNDAT(0x24)` 从 0 变为极小非零值，
  说明 PA 收到样本，但不能据此判定声压输出。
- **用户实听 FAIL**：默认 -22.5 dB 与临时 -7.5 dB 两次 440Hz 均完全
  无声。下一步继续查 I2S slot/channel、活动增益和 ACF profile。
- 完整证据：`notes/bisect-logs/linux-s5fy-aw-diag-20260817.txt`。

复测命令：

```sh
dmesg | grep -Ei 'aw88261|pll|sysst|pri_mi2s'
```
