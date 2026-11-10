#!/usr/bin/env bash
# SSH via the caller's key/agent; configure cerro-wifi in ~/.ssh/config.
set -euo pipefail
phone_user=${CERRO_SSH_USER:-user}
phone_target=${CERRO_SSH_HOST:-cerro-wifi}
# Normal OpenSSH host-key verification applies. No embedded password or stale DHCP IP.
exec ssh -o ConnectTimeout=5 "${phone_user}@${phone_target}" "$@"
