# audio-va-dmic-c1

## Why (superseded for handset)
Initial hypothesis: handset = VA DMIC. **Wrong for Aurora handset-mic** (amic1 /
TX_CODEC_DMA_TX_3). Keep this patch as VA-path experiment; handset capture
moved to `patches/audio-tx-amic-c1/`.

CERRO topology MultMedia2 was wired to `TERTIARY_MI2S_TX` (LEMANS borrow).
Builtin DTB also lacked VA Capture dai-link and `lpass_vamacro` pinctrl.

## Contents
- `SM8650-CERRO-tplg-va.bin` — same size as s5fz; retargets capture BE to
  `VA_CODEC_DMA_TX_0` (MODULE_ID / HW_IF from X13s reference).
- `out/boot-v2-s5gb-va-dmic-c1.img` — ipa-imem-memshare Image with early+appended
  DTB patched (`cerro_dtb=s5gb-va-dmic-c1`): VA dai-link + dmic01/23 pinctrl.
- Source DTS already has the same nodes in `linux/sm8650-nubia-cerro.dts`.

## Install
1. Replace `/lib/firmware/qcom/sm8650/SM8650-CERRO-tplg.bin` with the VA tplg.
2. Dual-slot flash the boot img (or `dd` `boot_a`/`boot_b`), erase `dtbo_*`.
3. **Hard power-cycle** (soft reboot still hangs on IPA STOP while cellular is up).
4. Verify: `cat /proc/cmdline` has `s5gb-va-dmic-c1`; `arecord -D hw:0,1` shows
   non-zero RMS with `MultiMedia2 Mixer VA_CODEC_DMA_TX_0` on.

Call earpiece / modem voice bridging is **not** this patch — only handset DMIC path.
