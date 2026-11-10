#!/usr/bin/env bash
# 主机端查看 Cerro 投屏（MJPEG）。手机侧服务：cerro-screen-server（:8660）。
# 用法：
#   cerro-screen-view.sh           # ffplay 实时流
#   cerro-screen-view.sh shot      # 抓单帧并显示
set -euo pipefail
PHONE_IP=${CERRO_PHONE_IP:-192.168.68.2}
PORT=${CERRO_SCREEN_PORT:-8660}
export no_proxy="$PHONE_IP" NO_PROXY="$PHONE_IP"

if [[ "${1:-}" == "shot" ]]; then
  out=/tmp/cerro-view-$(date +%H%M%S).jpg
  curl -s --noproxy "$PHONE_IP" --max-time 30 "http://$PHONE_IP:$PORT/shot.jpg" -o "$out"
  echo "$out"
  xdg-open "$out" >/dev/null 2>&1 || true
  exit 0
fi

exec ffplay -fflags nobuffer -flags low_delay -vf scale=-2:900 \
  "http://$PHONE_IP:$PORT/stream.mjpg"
