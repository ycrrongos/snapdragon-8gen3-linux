# audio s5fi — load qmi_helpers before PAS

## Why s5fh lost the card
`CONFIG_QCOM_Q6V5_PAS=m` needs `qcom_sysmon` → `qmi_helpers`.
Boot `cerro-audio-up` loaded PAS without QMI → Unknown symbol → no ADSP start →
90s card wait → empty cards. Later ath12k pulled `qmi_helpers` and PAS could load;
cards appeared only after a late re-run.

s5fg looked OK because `ExecStartPost` re-ran the script after WiFi had loaded QMI.

## Fix
- `loadm qmi_helpers` before `qcom_sysmon` / `qcom_q6v5` / `qcom_q6v5_pas`
- one-shot `depmod -a` (rootfs modules.dep incomplete for late-copied kos)
- keep s5fh card-poll + WSA route
- DTS `cerro_dtb=s5fi`
