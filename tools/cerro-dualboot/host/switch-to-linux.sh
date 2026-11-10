#!/bin/bash
# Host command. Preserve the current slot; cache its Android boot/dtbo opposite.
set -euo pipefail
exec python3 "$(dirname -- "$(readlink -f -- "$0")")/switch-system.py" linux "$@"
