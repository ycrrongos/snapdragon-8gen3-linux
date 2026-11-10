#!/usr/bin/env bash
# Share host internet to cerro over USB ECM (phone expects 192.168.68.2/24 via .1).
set -euo pipefail
HOST_IP=192.168.68.1
NET=192.168.68.0/24

sudo modprobe cdc_ether cdc_ncm 2>/dev/null || true

pick_iface() {
  local i mac
  # ONLY match planted gadget host_addr — never grab unrelated cdc_ncm (s5bz trap).
  for i in $(ls /sys/class/net); do
    case "$i" in lo|wlan*|docker*|virbr*|vmnet*|br-*|tailscale*|tun*) continue ;; esac
    mac=$(cat "/sys/class/net/$i/address" 2>/dev/null || true)
    if [[ "$mac" == "02:11:22:33:44:56" ]]; then
      echo "$i"; return 0
    fi
  done
  return 1
}

IFACE="${1:-}"
if [[ -z "$IFACE" ]]; then
  IFACE=$(pick_iface || true)
fi
[[ -n "${IFACE:-}" ]] || { echo "ERROR: no USB ethernet iface; is phone ECM up?"; ip -br link; exit 1; }

echo "using IFACE=$IFACE"
sudo ip link set "$IFACE" up
sudo ip addr flush dev "$IFACE" 2>/dev/null || true
sudo ip addr add "$HOST_IP/24" dev "$IFACE"
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
# NAT out via default route iface (usually wlan0)
WAN=$(ip route show default | awk '{print $5; exit}')
[[ -n "$WAN" ]] || { echo "WARN: no default route on host"; WAN=wlan0; }
sudo iptables -t nat -C POSTROUTING -s "$NET" -o "$WAN" -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -s "$NET" -o "$WAN" -j MASQUERADE
sudo iptables -C FORWARD -i "$IFACE" -o "$WAN" -j ACCEPT 2>/dev/null \
  || sudo iptables -A FORWARD -i "$IFACE" -o "$WAN" -j ACCEPT
sudo iptables -C FORWARD -i "$WAN" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || sudo iptables -A FORWARD -i "$WAN" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "OK: $IFACE $HOST_IP/24  NAT via $WAN"
echo "On phone: ping -c1 $HOST_IP ; ping -c1 1.1.1.1 ; apk update"
ip -br addr show dev "$IFACE"
