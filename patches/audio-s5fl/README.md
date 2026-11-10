# audio-s5fl — WSA SD_N drive raw HIGH

## Evidence (s5fk)
- SWR enumerator on `6b10000` empty (no `0x02170220/221`); WCD enum OK.
- Left LPASS gpio21 stuck `out 0` despite ACTIVE_LOW deassert; right TLMM77 high.
- Empty bus → zero audible sound; do not paplay until Attached.

## Change
- `wsa884x.c`: enable with `gpiod_direction_output_raw(..., 1)` (phys HIGH =
  out of SD_N); powerdown raw 0; null-safe.
- Stage patched `snd-soc-wsa884x.ko` via initramfs → rootfs (existing copy path).
- Tag `cerro_dtb=s5fl`

## Accept
Both `sdw:1:0:0217:0204:00:{0,1}` Attached **or** enumerator shows
`id1=0x02170220/221`. gpio21/77 physical high. No playback until then.
