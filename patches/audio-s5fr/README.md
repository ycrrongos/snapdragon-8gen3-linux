# audio-s5fr — stop WSA, start AW88261

## Why
AOSP/stock: `wsa-macro` **disabled**; speakers = 2× AW88261 (chipid `0x2113`) on
`i2c_hub_3` @ `0x34`/`0x35`. s5fk–s5fq WSA enum-empty was wrong SKU.

## Change
- DTS `cerro_dtb=s5fr`: `&swr0` disabled; drop WSA dai-link / routing.
- `&i2c_hub_3` okay + `awinic,aw88261` @34 (ch=1) / @35 (ch=0).
- `dvdd-supply = vreg_l15b_1p8`; `firmware-name = aw882xx_acf.bin`.
- `CONFIG_SND_SOC_AW88261=y` (+ lib); stage ACF via initramfs/`cerro-init`.
- Gold: `notes/bisect-logs/aosp-aw882xx-gold-20260817.txt`.

## Accept (this gun)
- dmesg: `chip id = 2113` on both addrs; `/sys/bus/i2c/devices/*-0034` bound.
- No playback yet (MI2S/I2S0 gpio126–129 dai-link next).

## Later
- pri_mi2s / i2s0 pinctrl + sound dai-link for audible speakers.
