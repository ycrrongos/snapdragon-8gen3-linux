# power-pmic-glink-c1

Cerro builtin DTB 没有 `pmic-glink`，`qcom_battmgr` 永不 probe，
`/sys/class/power_supply` 为空。

## 根因（EAGAIN）

上游 `pmic_glink` 等 ADSP PDR `charger_pd`。Cerro live servreg **没有**
该服务 → `tms/servreg` lookup `-ENOENT` / capacity **EAGAIN**。
补丁 `0001-pmic-glink-skip-charger-pd-pdr.patch`：去掉 PDR 门闩，RPMSG 即 UP。

## 实机 PASS（2026-10-19）

与 Android 对齐：`charge_type=Fast`，UCSI `PD PD_PPS`，`status=Charging`。

| 组件 | 作用 |
|------|------|
| `cerro-pmic-glink-overlay.ko` | runtime 挂 `/pmic-glink` |
| `pmic_glink.ko` | no-PDR |
| `qcom_battmgr.ko` | bat/usb/wls psy |
| `typec_ucsi.ko` + `ucsi_glink.ko` | Type-C / PD / PPS |
| `battmgr.jsn` | → `/lib/firmware/qcom/sm8650/`（pd-mapper） |
| `cerro-battmgr.service` | 开机 modprobe 顺序 |

安装：主机 ECM `192.168.68.1/24` + `python3 -m http.server 8768`，
手机跑 `install-on-phone.sh`（**校验 .ko 字节数**，防 0 字节假装）。

## Permanent

`linux/sm8650-nubia-cerro.dts` 已加 MTP 式节点；下次 builtin-DTB Image
重建后可去掉 runtime overlay。

## charge_full fix (2026-10-21)
- Patch: `0002-qcom-battmgr-sm8550-default-unit-mAh.patch`
- Symptom: `charge_full`/`charge_full_design` ENODATA on SM8650 (SM8550 props)
- Cause: unit default mWh; property path never sets unit
- Fix: force unit=mAh for SM8350/SM8550; add sm8650 of_match
- Verify: charge_full=6080000 charge_full_design=6000000
