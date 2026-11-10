# audio-s5ft — CONFIG_I2C_QCOM_GENI=y

## Why (s5fs)
`9c0000.geniqup`/`98c000.i2c` 已出现，但无 i2c adapter：`CONFIG_I2C_QCOM_GENI=m` 且 rootfs/initramfs **未带** `i2c-qcom-geni.ko`。

## Change
- `CONFIG_I2C_QCOM_GENI=y`
- `cerro_dtb=s5ft`
