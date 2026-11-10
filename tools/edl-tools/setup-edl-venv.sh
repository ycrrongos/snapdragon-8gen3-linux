#!/usr/bin/env bash
# Create venv + install bkerler/edl (clone if missing).
set -euo pipefail
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TOOL"
if [[ ! -d edl ]]; then
  echo "Cloning bkerler/edl into $TOOL/edl ..."
  git clone --depth 1 https://github.com/bkerler/edl.git
fi
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate
pip install -U pip wheel
pip install -r edl/requirements.txt
echo "OK: $TOOL/venv — run: source $TOOL/edl-env.sh"
echo "NOTE: place SM8650 v1 firehose in $TOOL/nubia_sm8650_eng/ (see tools/edl-tools/README.md)"
