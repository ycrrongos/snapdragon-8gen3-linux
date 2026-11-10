#!/bin/bash
set -euo pipefail
install -m 644 "$(dirname "$0")/cerro-ipa-nosuspend.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now cerro-ipa-nosuspend.service
echo IPA_NOSUSPEND_INSTALLED
