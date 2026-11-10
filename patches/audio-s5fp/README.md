# audio-s5fp — swr0 again + WSA keep-on + delayed re-enum

## Why
s5fo (WSA2/swr3) still empty enum → amps stay on swr0 path.
s5fn-era: autosuspend left `SWR_CONTROL=0`; first enum may race ADSP/q6prm.

## Change
- DTS: speakers back on `&swr0`; dai-link `swr0`+`lpass_wsamacro`; `cerro_dtb=s5fp`.
- Keep SD_N hog HIGH (from s5fn).
- `soundwire-qcom.c` (label WSA): `pm_runtime_forbid` + delayed `qcom_swrm_init` @2.5s.
- Keep `lpass-wsa-macro` `pm_runtime_forbid` (s5fo).
- **Must** copy DTB → `arch/arm64/kernel/sm8650-nubia-cerro.dtb` before Image.

## Accept
`sdw:1:0:0217:0204:00:{0,1}` Attached or swr0 enumerator non-zero.
dmesg: `cerro s5fp: WSA delayed re-enum done`. No playback until Attached.
