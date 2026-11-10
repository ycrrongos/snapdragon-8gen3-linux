# agent_phone_tool

串口舵机按键手：协议不变（`PING` / `G` / `SA:a,b,c` / `PRESS*` / `REST*` / `R`）。

## 固件

```bash
cd firmware
```

| 板子 | PlatformIO env | 舵机脚（顶面丝印） |
|------|----------------|-------------------|
| **FireBeetle 2 ESP32-S3 V1.0** | `firebeetle2_esp32s3` | **A0=Vol+ A1=Vol- A2=Power**（GPIO 4/5/6） |
| ESP32-S3 DevKit | `esp32_s3` | GPIO4 / 5 / 9 |
| STM32F103 Blue Pill | `stm32f103_bluepill` | A4/A5/A6 = PA4/5/6 |
| STM32 + ST-Link | `stm32f103_bluepill_stlink` | 同上 |
| Nano | `nanoatmega328` | 板载默认 |

板型配置对齐 `/mnt/data/innox_echo/hardware/echo-esp32`（`board = dfrobot_firebeetle2_esp32s3`）。

### FireBeetle 2 烧录

```bash
pio run -e firebeetle2_esp32s3 -t upload --upload-port /dev/ttyACM0
# 或沿用 echo 脚本习惯：
# /mnt/data/innox_echo/hardware/echo-esp32/flash.sh /dev/ttyACM0 esp32-s3
pio device monitor -e firebeetle2_esp32s3 -b 115200
```

上电应看到：

```
READY agent_phone_tool
BOARD firebeetle2_esp32s3 silk A0=VOL+ A1=VOL- A2=POWER
```

舵机请用 **独立 5V**，勿从 3V3 取大电流。

### STM32 烧录

USB-UART（CH340）接 USART1，BOOT0=1：

```bash
pio run -e stm32f103_bluepill -t upload --upload-port /dev/ttyACM0
```

## 主机 CLI / 校准 UI

`servo_cli.py` / `server/`；Cerro 副本：`LOA_Nubia_Z60U/tools/agent-phone/`。
