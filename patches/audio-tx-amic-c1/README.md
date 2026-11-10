# audio-tx-amic-c1

## Why
Aurora `handset-mic` is **amic1** (tx_macro + SoundWire ADC1 / SWR_MIC4), BE
`TX_CODEC_DMA_TX_3` — not VA DMIC. Stock CERRO tplg still had Tertiary MI2S.

VA-only retarget (`audio-va-dmic-c1`) opened graph 110 after DAI_INDEX fix but
RMS stayed ~0; this candidate matches Aurora + DTS `wcd-capture-dai-link`.

## Contents
- `SM8650-CERRO-tplg-tx.bin` — from s5fz via `tools/patch-cerro-tplg-tx-capture.py`
  (MODULE CODEC_DMA, HW_IF_TYPE=1 IDX=4, DAI_INDEX=120, strings → TX_CODEC_DMA_TX_3).
  SHA-256 `67a093d0…`.

## Live result (2026-10-17)
Soft reboot, mixer amic1 path, `arecord -D hw:0,1 -c2 -r48000`:
**rms≈5654 peak=32768** with ADC1 unmute + TX_DEC0 100% (clipping = real mic).

## Install
```bash
# host
python3 tools/cerro-acm-push.py --sudo --user rong --password <device-local> \
  patches/audio-tx-amic-c1/SM8650-CERRO-tplg-tx.bin \
  /usr/lib/firmware/qcom/sm8650/SM8650-CERRO-tplg.bin
# phone: sync; reboot  (soft reboot OK as of 10-17)
```

UCM: `notes/alsa-ucm-sm8650-cerro/HiFi.conf` Mic section.

Call earpiece / modem voice bridging is still separate.
