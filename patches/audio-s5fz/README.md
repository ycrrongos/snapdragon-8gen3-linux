# audio-s5fz — PRIMARY_MI2S SD1 audible PASS

## Hypothesis

`s5fy` proves PCM setup, BCLK/LRCLK, AW88261 PLL/SYSST/start and unmute, but the
user confirms complete physical silence. Repeated 1 kHz sampling shows both PA
`VSNDAT=0` and only sensor-noise-level `ISNDAT`, so there is no real speaker
terminal output.

Stock pinctrl declares both `i2s0_data0` (gpio127) and `i2s0_data1` (gpio128).
The borrowed LEMANS topology selects only `AR_TKN_U32_MODULE_SD_LINE_IDX=1`
(`I2S_SD0`). This slice cold-tests value `2` (`I2S_SD1`) without changing the
rest of the audio graph or AW driver.

## Delta

- topology offset 6052 remains token 256; value at 6056 changes 1 → 2;
- DTB tag changes to `cerro_dtb=s5fz`;
- AW s5fy diagnostics remain enabled.

Generated with `tools/patch-cerro-tplg-sd-line.py`. A hot machine-driver
unbind/rebind was attempted first, but Audioreach left the old graph allocated
and reprobe failed (`CMD timeout`, PCM buffer allocation `-22`). Reboot restored
the original SD0 topology/card, so SD1 must be evaluated from a cold boot.

## Result (2026-08-17)

- topology SHA256:
  `866b22ffd144639732e50a0a2b8940f9340c73d0ac2cab1d71b2b8af1809737c`;
- boot image: `build/boot_repack/boot-v2-disp-dpu-s5fz.img`, SHA256
  `378b4bdc768061e4dcf3613a40e89094cc6448f324a8bdd3b157fc4b9ce4ea4c`;
- flashed to both boot slots at 14:29 through real `05c6:9008`; stock
  vendor_boot restored to both slots and both dtbo slots erased;
- boot identity `cerro_dtb=s5fz` and the runtime topology hash were verified;
- the user confirmed the 1 kHz test was audible;
- a follow-up played 700 Hz on logical left, paused, then 1200 Hz on logical
  right; the user confirmed both segments were audible;
- during SD1 playback, PA 0x34 reported real IV activity
  (`ISNDAT=-20…47`, `VSNDAT=-28…69`), whereas PA 0x35 still reported
  `VSNDAT=0`;
- a subsequent PA-isolation test attenuated the other amp to mixer value 0,
  then played 800 Hz through 0x34 and 1400 Hz through 0x35. The user confirmed
  both segments were audible, so both physical amp paths pass. The 0x35
  `VSNDAT=0` result is a feedback-reading anomaly, not evidence of silence;
- the KDE user's real PulseAudio default sink is `cerro_speaker`. Four Plasma
  Ocean theme sounds (login, information, success and warning) were played
  through it with `paplay`; all returned 0 and the user confirmed normal sound;
- final readback showed `SpkrLeft PCM Playback Volume` and `SpkrRight PCM
  Playback Volume` both restored to 270 / -22.5 dB. The PulseAudio sink
  remained at balanced 70% and unmuted.

The root cause of the s5fy silence was therefore the topology selecting SD0;
this device's working speaker playback line is SD1/gpio128.
