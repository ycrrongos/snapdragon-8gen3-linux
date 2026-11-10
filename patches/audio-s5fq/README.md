# audio-s5fq — SD_N powerdown pulse + keep s5fp re-enum

## Why
s5fp: master stay-on + delayed re-enum → `slv_status=0`, enum slots still empty.
Clocks/link OK (`0x5060/5064` match WCD). Suspected missing SD_N rising edge.

## Change
- DTS: remove SD_N gpio-hogs; restore QRD `powerdown-gpios` on gpio21/77; `cerro_dtb=s5fq`.
- `wsa884x`: on deassert, pulse SD_N raw L (10ms) → H (20ms settle).
- Keep `soundwire-qcom` WSA `pm_runtime_forbid` + delayed re-enum (4s).
- Sync builtin DTB: `cp boot/dts/.../dtb → arch/arm64/kernel/`.

## Result (2026-08-17 00:05)
- Tag `cerro_dtb=s5fq` OK; both `SD_N reset pulse done` before master keep-on.
- `re-enum done (slv_status=0x0)`; still UNATTACHED; `0x530+` all 0.
- WSA macro `SWR_CONTROL(0x8)=1` (clk on) — not the card.
- **Next**: AOSP live WSA dump, or ADSP/SPF ownership of swr0 pads.

## Accept (not met)
Attached or non-zero enum. No playback until then.
