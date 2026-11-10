#!/bin/sh
# Both present USIM provisioning sessions are real MM hardware prerequisites.
# Does not power off cards, guess PINs or delay an unrelated boot target.
set -eu
exec /usr/local/libexec/cerro-cellular-c1/prepare_dual_usim.py
