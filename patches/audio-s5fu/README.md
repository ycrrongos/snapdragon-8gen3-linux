# audio-s5fu — AW88261 + PRIMARY_MI2S (i2s0)

## Why
s5ft: AW I²C probe PASS, but no PCM path. AOSP speakers use pri_mi2s / i2s0
(gpio126 sck, 129 ws, 127 data0, 128 data1).

## Changes
- DTS: `pri_mi2s_active` pinctrl; `aw-playback-dai-link` →
  `q6apmbedai PRIMARY_MI2S_RX` + `spkr_left`/`spkr_right`
- Topology: replace QRD/WSA stub with **LEMANS-EVK** tplg (has
  `PRIMARY_MI2S_RX` / MultiMedia1). Old stub kept as
  `notes/firmware-adsp-sm8650/SM8650-CERRO-tplg-qrd-wsa-stub.bin`
- `cerro_dtb=s5fu`
- Do **not** embed full ath12k tree in initramfs (boot partition 96MiB).

## Verify (no paplay) — PASS 2026-08-17
- `cerro_dtb=s5fu`; AW `chip id = 2113`
- pinmux: gpio126–129 claimed by `sound` as `i2s0_*`
- After ADSP start + qmi/apr/q6apm loaded: card `SM8650-CERRO`,
  `MultiMedia1 Playback`, mixer `PRIMARY_MI2S_RX Audio Mixer MultiMedia1`
- DAPM: `SpkrLeft Speaker_Playback` ← `Primary MI2S Playback`

## Follow-ups
1. ~~Pack `qmi_helpers` …~~ → **done in s5fv**
2. ~~UCM: route HiFi → MI2S~~ → **done in s5fv**
3. WiFi: stage ath12k via rootfs tarball / larger partition path — not boot.img.
4. Attached path before `paplay`.
