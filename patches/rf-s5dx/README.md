# s5dx RF / PCIe power-on fixes (applied in build/linux)

1. `pci-pwrctrl-pwrseq.c` — force `pwrseq_power_on` in probe (cerro logs).
2. `pcie-qcom.c` `qcom_pcie_host_init` — always call `pci_pwrctrl_power_on_devices` on cold boot (ignore `skip_pwrctrl_off` for power-*on*).
3. `PCI_PWRCTRL_PWRSEQ=y` (Kconfig prompt + ath12k `imply` instead of `select`).
4. DTS `cerro_dtb=s5dx`: PERST/wake on `&pcie0` as `perst-gpios`/`wake-gpios`.

Result (s5dx era): WLAN_EN high + wlan-enable=1, but still no `17cb:1107` endpoint.

## s5eo (2026-08-16) — kiwi enum

`pcie-qcom.c` adds before LTSSM:

1. Minimal CRM MMIO at `0x1d01000` — HW-DRV0 channel switch, PERF_OL=GEN4 (`0x5`) for all PERF VCDs (`curr_perf_ol[0]=0x5`).
2. Keep PARF `+0x2c48` CLKREQ_SEL (do **not** clear like s5en).
3. Apply AOSP pineapple `qcom,phy-sequence` (115 writes) via `cerro-phy-seq.inc`.

Verified on device: **PCIe Gen.2 x2 link up**, EP **`17cb:1107`**.  
WiFi userspace (2026-08-16): load **`ath12k` + `ath12k_wifi7`**, firmware under `ath12k/WCN7850/hw2.0/` (cerro board-2 entry for subdev 1107 / board_id 255). See `notes/firmware-kiwi/ath12k-WCN7850-hw2.0/` — `wlan0` + `nmcli device wifi list` PASS.
