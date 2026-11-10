#!/bin/sh
set -eu
# Resolve ownership from the actual OF path, never assume adapter numbers.
for adapter in /sys/bus/i2c/devices/i2c-*; do
 case "$(readlink -f "$adapter/of_node")" in
  */cci@ac16000/i2c-bus@*)
   bus=${adapter##*/i2c-}
   for client in /sys/bus/i2c/devices/"$bus"-*; do
    if test -e "$client"; then echo 'CCI1 has a client; refusing'; exit 2; fi
   done
   ;;
 esac
done
test "$(readlink -f /sys/bus/platform/devices/ac16000.cci/driver)" = /sys/bus/platform/drivers/i2c-qcom-cci
printf '%s' ac16000.cci > /sys/bus/platform/drivers/i2c-qcom-cci/unbind
if test "${1-}" != --release-only; then
 for client in /sys/bus/i2c/devices/*-0010; do
  if test "$(readlink -f "$client/of_node")" = /sys/firmware/devicetree/base/soc@0/cci@ac15000/i2c-bus@1/camera-id@10; then
   printf '%s' "${client##*/}" > /sys/bus/i2c/drivers_probe
  fi
 done
fi
