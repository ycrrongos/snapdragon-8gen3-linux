# sensors-fastrpc-c1

## Why
Cerro auto-rotate needs LSM6DSO. Aurora puts it on the sensor island
(`lanai_lsm6dso_0.json` `bus_type=1`). On SM8650 the sensor FastRPC skels
(`libsns_*.so`, `sns_tppe.so`) live under `dsp_a/adsp/`, not a separate SLPI
image. Mainline had `CONFIG_QCOM_FASTRPC=m` but the module was never shipped
in the Debian module tree.

## What
- Built `fastrpc.ko` from `build/linux-7.2` (`vermagic 7.2.0-rc5-dirty`).
- Live: `modprobe fastrpc` → `/dev/fastrpc-adsp` appears (ADSP glink-edge).
- dmesg also warns `no reserved DMA memory for FASTRPC` — may need a DMA
  reserved-memory node later for real RPCs.

## Still missing for auto-rotate
Userspace SSC client (Android `sensors.qti` / open `libssc`) + sensor registry
JSON. Kernel device alone does not export IIO accel nodes.

## Install (phone)
```
install -m 0644 fastrpc.ko /lib/modules/$(uname -r)/extra/
depmod -a
modprobe fastrpc
```
