# cellular-ims-c1 — VoLTE IMS stack on Cerro Linux

## Status 2026-10-21 23:14

| Step | Result |
|------|--------|
| `81voltd` (IMS DCM / service 770) | PASS after `PrivateNetwork=no` |
| openimsd `libqmi` → `/opt/cerro/libqmi-openimsd` | PASS (1.39.0 fork) |
| `qcom-imsd` (bind + enable VoLTE/reg/data) | PASS (wait_events) |
| IMSA registration | PASS `registered` / Voice `available` |
| MO `mmcli` 10086 | PASS `state=active` (was dialing→terminated) |
| IMS bearer `apn=ims` IPv6 `qmapmux0.1` | PASS (iface often needs explicit `up`) |
| WWAN `qmapmux0.0` after IMS | PASS HTTP 204 |
| AGM VOICEMMODE RX during/around call | FAIL `start=-131`; leftover `open=-68` |
| Media HiFi after call | PASS paplay |

## Root cause of earlier MO fail

联通 VoLTE：无 IMS AP daemon 时 QMI voice 一直 `mode=lte` origination，卡在 dialing。  
`81voltd` + `qcom-imsd` 后 IMS 注册成功，建呼可到 `active`。

## Critical pitfalls

1. **Debian `81voltd.service` 默认 `PrivateNetwork=yes`** → `AF_QIPCRTR` errno 97。必须 drop-in `PrivateNetwork=no`。
2. **stock libqmi 1.36 不够**；要用 openimsd fork（本机装到 `/opt/cerro/libqmi-openimsd`），`GI_TYPELIB_PATH`+`LD_LIBRARY_PATH` 指向它。
3. **`qcom-imsd` + `python-statemachine` 3.x**：`self._config` 会被 StateMachine 的 `Configuration` 覆盖 → 改成 `_imsd_cfg`。
4. **PolicyManager API 命名**：fork 是 `*Settings`（复数）；上游 qcom-imsd 源码写的是 `*Setting`。
5. **GEnum 无 `.name`**：pygobject 上要用 `value_nick`（`enum_nick()`）。
6. **IMS mux**：MM bearer connected 后 `qmapmux0.1` 常仍 DOWN，需 `ip link set up` + 配 IPv6（见 `cerro-ims-iface.sh`）。
7. **勿** `echo stop > adsp` 清 AGM；残留图用冷启清。

## Install (phone)

前置：已有 `81voltd` apt 包、手机上编好的 `/opt/cerro/libqmi-openimsd`、`~/src/qcom-imsd` venv。

```bash
# from repo
./patches/cellular-ims-c1/install.sh
```

## Accept

```bash
systemctl is-active 81voltd cerro-qcom-imsd
qmicli -p -d qrtr://0 --client-no-release-cid --imsa-bind=0
# then with CID: --imsa-get-ims-registration-status  → registered
mmcli -m 0 --voice-create-call=number=10086 && mmcli -o N --start
# expect state=active
```

远端 PCM：仍缺 AGM RX `start=0` 且需 TX Fluence；禁止用 UCM sidetone 冒充 PASS。
