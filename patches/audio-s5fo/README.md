# audio-s5fo — WSA2 bus (swr3) + keep WSA macro powered

## Evidence (s5fn live)
- SD_N LPASS21 VALUE_REG OUT=1 / IN=1 — **not** the card.
- `6b00000` / `6b10000` were **runtime suspended**; MMIO `SWR_CONTROL` often **0**
  while clk_summary still showed iface enabled (CCF/HW desync).
- Soft-reset of swr0 raised `MASTER_CLASH_DET`; forcing PM `on` + `SWR_CONTROL=1`
  made COMP_STATUS look healthy (`0x100001`) but **enumerator still empty**.
- Stopping ADSP to test clash → USB/gadget death (do not repeat casually).
- **Build pit**: Image uses `arch/arm64/kernel/sm8650-nubia-cerro.dtb` — must copy
  fresh `boot/dts/.../sm8650-nubia-cerro.dtb` there before `make Image`.

## Change
- DTS: disable `&swr0`; put left/right WSA884x on `&swr3` (WSA2 / gpio15–16);
  dai-link → `swr3` + `lpass_wsa2macro`; tag `cerro_dtb=s5fo`.
- `lpass-wsa-macro.c`: `pm_runtime_forbid()` after enable (both WSA macros).
- Image: `boot-v2-disp-dpu-s5fo.img`.

## Result (2026-08-16 23:39)
- Boot tag `cerro_dtb=s5fo` OK; gpio15/16 = `wsa2_swr_{clk,data}` on `6ab0000`.
- `sdw:4:0:0217:0204:00:{0,1}` still **UNATTACHED**; swr3 enum all 0; CMD errors.
- **Not** a “amps are on WSA2” board: next gun stays on **swr0**.

## Accept (not met)
`sdw:*:0217:0204:*` Attached **or** enumerator non-zero. No playback until then.
