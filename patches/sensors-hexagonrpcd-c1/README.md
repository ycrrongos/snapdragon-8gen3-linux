# sensors-hexagonrpcd-c1

## PASS (2026-10-17)
- `fastrpc.ko` → `/dev/fastrpc-adsp`
- `hexagonrpcd -s -R /usr/share/qcom/` (INIT_ATTACH_SNS)
- Android `persist` mounted at `/mnt/vendor/persist`
- HexagonFS registry synced (299 entries, includes `lanai_lsm6dso_0.*`)
- Units: `mnt-vendor-persist.mount`, `cerro-sensors-registry.service`, drop-ins under `hexagonrpcd.service.d/`

## FAIL / gap
- No IIO devices; auto-rotate not working
- `sensh` (QRTR/QMI SNS client) times out — SM8650 SEE talks FastRPC, not QRTR SNS
- Android 对照（2026-10-21）：`sscrpcd sensorspd` 打开 `/dev/adsprpc-smd-secure`，链到 `libssc_default_listener.so` → `adsp_default_listener_start` / `remote_handle_open("adsp_default_listener")`（QCOM proprietary adsprpc）。`adsps.jsn` subdomain=`sensor_pd`。
- Next：Linux 上对齐 **sensor_pd + FastRPC default listener（类 sscrpcd）**，再接 SEE 读数→iio-sensor-proxy；不要再装 libssc/QRTR sensh，也不要只靠再堆 registry

## DIR log line
`Tried to open .../registry/DIR for writing` is the DSP mkdir sentinel; stock Android registry also contains a `DIR` entry. Not a missing-file failure once registry is populated.
