# audio s5fe — start ADSP before q6prm/macros

## Why
s5fd: PAS OK, ADSP `running`, but ALSA still missing.
Deferred: `va_macro: unable to get macro clock` (clocks from `q6prm-lpass-clocks`
under GPR `adsp_apps`). Old `cerro-audio-up.sh` loaded macros **before** ADSP start.

## Change
`tools/cerro-init/init` → `cerro-audio-up.sh`:
1. Load remoteproc stack + `qcom_q6v5_pas`
2. `echo start` ADSP, wait `running` + rpmsg `adsp_apps`
3. Then load apr / q6prm / macros / codecs / machine
4. Fix `loadm` hyphen vs underscore lsmod check

Keeps s5fd memblock skip (`<0xa0000000`).
