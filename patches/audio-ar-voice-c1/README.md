# audio-ar-voice-c1 — ARGS VOICEMMODE on Cerro Linux

## Status 2026-10-22 07:15（AGM 自动路径作废 — 挂断卡死媒体）

| Step | Result |
|------|--------|
| Dialer 接打（信令） | PASS（用户确认） |
| 远端声 | FAIL |
| 挂断后媒体 | 曾 **FAIL**（MultiMedia1/suspend 残留）→ 已回退单通道 HiFi |
| 当前 AP | **HiFi only** + Earpiece/Speaker；**不**自动跑 AGM |
| AGM 探针 | `cerro-voice-agm.sh` start **禁用**；仅 `stop`/`restore-media` |

**教训**：为 AGM 断开 `PRIMARY_MI2S_RX Audio Mixer MultiMedia1` + `pactl suspend-*` 会把 PipeWire PCM 卡死到只能重启。Dialer 路径禁止再这么干。远端声要另找不拆 MultiMedia1 的办法（或官方 PAL voip 节点）。

### 正确共存（2026-10-22 探针）

**禁止**：`systemctl --user stop pipewire*` 换 AGM start（毁媒体、被用户否决）。

**做法**：

1. `cerro-voice-bridge on` → VoiceCall + 听筒 mixer（10-17）。
2. 卸 sidetone loopback；可选 `pactl suspend-sink`。
3. **`PRIMARY_MI2S_RX Audio Mixer MultiMedia1` → off,off**（VoiceCall UCM 默认 on，占住 BE → AGM `start=-131`）。
4. `cerro-vcall-rxtx` / `cerro-voice-agm.sh start` → RX `start=0` + Proxy TX `start=0`，**PipeWire 仍 active**。
5. 挂断：`agm stop` → MultiMedia1 on → `voice-bridge off`。

pmOS `q6voiced` / `hw:0,4` **不适用** SM8650 AudioReach（2026-05 官方说明）。远端走 AGM HOSTLESS VOICEMMODE，不是 host CVD PCM。

## Critical pitfalls

1. ~~停 PipeWire 换 AGM~~ → **作废**。改断 MultiMedia1→MI2S。
2. `agm_session_set_config`：HOSTLESS 也要非 NULL `agm_buffer_config`。
3. 缺 `agm_aif_set_media_config` → prepare −131。
4. Leftover graphs → open −68；冷启清，**勿** `echo stop > adsp`。
5. `/dev/aud_pasthru_adsp` 冷启常缺：等 `q6apm-dais` 再 `modprobe cerro-audio-shmem cerro-aud-pasthru`（`modules-load` 太早会失败）。
6. `q6voiced hw:0,4` 主线无该 PCM，可忽略。

## Probes

```bash
# coexist (preferred): VoiceCall + MM1 off + AGM, PW stays up
cerro-voice-bridge on
sudo cerro-voice-agm.sh start 3600 proxy
# … dial …
sudo cerro-voice-agm.sh stop
cerro-voice-bridge off

# raw
sudo env LD_LIBRARY_PATH=/usr/local/lib /usr/local/sbin/cerro-vcall-rxtx 30 proxy
```

`cerro-mm-voice-watch`：bridge on → AGM start；挂断反过来。默认 Proxy TX。
