# audio-s5fs — enable i2c_master_hub_0 for AW88261

## Why (s5fr)
Module + ACF + `cerro_dtb=s5fr` OK，但 `/sys/bus/i2c/devices` 空：
`&i2c_hub_3` okay 而父 **`&i2c_master_hub_0` (geniqup@9c0000) 仍 disabled**。

## Change
- `&i2c_master_hub_0 { status = "okay"; }`
- `cerro_dtb=s5fs`

## Accept
- `9c0000.geniqup` / `98c000.i2c` in sysfs
- dmesg `chip id = 2113` ×2；`*-0034`/`*-0035` bound to `aw88261`
