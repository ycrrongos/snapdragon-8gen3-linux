#!/bin/bash
# Run when FlClash/GitHub works. Installs upstream phone-porting skill user-wide.
set -euo pipefail
DEST="${HOME}/.agents/skills/linux-phone-porting"
export ALL_PROXY="${ALL_PROXY:-socks5://127.0.0.1:7890}"
export HTTPS_PROXY="${HTTPS_PROXY:-$ALL_PROXY}"
if [ -d "$DEST/.git" ]; then
  git -C "$DEST" pull --ff-only
else
  mkdir -p "$(dirname "$DEST")"
  git clone --depth=1 https://github.com/angelwzr/linux-phone-porting.git "$DEST"
fi
echo "installed: $DEST"
ls "$DEST/SKILL.md"
