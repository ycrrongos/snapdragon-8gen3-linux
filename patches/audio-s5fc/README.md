# audio s5fc — ADSP controlled start

## Changes
- `qcom_q6v5_pas.c`: `sm8650-adsp-pas` uses `sm8650_adsp_resource_cerro` with **`auto_boot=false`** (s5fa hung on auto start before getty).
- `qcom_scm.c`: `pr_info` for PAS metadata DMA phys (`cerro-pas: init_image …`).
- DTS: `remoteproc_adsp` `status=okay`, `cerro_dtb=s5fc`.
- `cerro-audio-up.sh`: stage `modem_a` fw → load modules → `echo start` ADSP.

## Builtin DTB
Always: `cp arch/arm64/boot/dts/qcom/sm8650-nubia-cerro.dtb arch/arm64/kernel/` and remove `.dtb.o` before `make Image`.
