#!/bin/bash
# Host command. Restore cached Android boot/dtbo into the same active slot.
set -euo pipefail
exec python3 "$(dirname -- "$(readlink -f -- "$0")")/switch-system.py" android "$@"
