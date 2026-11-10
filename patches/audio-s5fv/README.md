# audio-s5fv — cold-boot qmi + MI2S UCM

## Why
s5fu: MI2S path PASS only after USB ECM push of `qmi_helpers` + manual ADSP
start. Slimming s5fu initramfs had stripped `qmi_helpers` with ath12k.

## Changes
- Pack `qmi_helpers.ko` into embedded initramfs (apr/q6* already present)
- UCM HiFi → `PRIMARY_MI2S_RX Audio Mixer MultiMedia1` / `hw:0,0` (drop WSA)
- `cerro-audio-up.sh` / session: MI2S route (not WSA MultiMedia2)
- `cerro_dtb=s5fv`
- Still **no** full ath12k in boot.img (96MiB limit)

## Verify (no paplay) — PASS 2026-08-17 cold boot
- `cerro_dtb=s5fv`
- `qmi_helpers` on rootfs + loaded; ADSP `running`
- `cerro-audio: card ready after 1s`; `PRIMARY_MI2S MultiMedia1 speaker route applied`
- `aplay -l` → MultiMedia1; mixer `PRIMARY_MI2S_RX Audio Mixer MultiMedia1`

## Play attempt 2026-08-17 — FAIL
- `aplay -D hw:0,0` → hw_params EINVAL
- DSP `APM_CMD_SET_CFG` / `error[1001006]` → `Failed to set media format -22` on PRI_MI2S_RX
- `LPASS_CLK_ID_PRI_MI2S_IBIT` enable_count=0 (sc8280xp lacks sm8250-style set_sysclk; q6i2s_ops has no set_sysclk)
- Log: `notes/bisect-logs/linux-s5fv-play-fail-20260817.txt`

## Follow-ups
1. Enable PRI_MI2S_IBIT via q6prm / bedais set_sysclk (or sc8280xp startup), then retry play
2. WiFi: stage ath12k via rootfs / larger path — not boot.img
