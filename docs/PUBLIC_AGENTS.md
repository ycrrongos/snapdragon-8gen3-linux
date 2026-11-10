# Snapdragon 8 Gen 3 Linux — agent contract

This repository ports mainline Linux to SM8650 phones; only Cerro is tested.
Read docs/STATUS.md, docs/BUILDING.md and kernel/source.lock.json first.

- Current queue: Waydroid kernel support, then front/ultrawide/tele cameras and
  remaining main-camera quality/UI work, then accelerometer. The owner accepted
  the main camera as basically usable; do not claim Android parity.
- No subagents for phone/boot/kernel work. One variable and a written hypothesis,
  falsifier, rollback and regression list per experiment.
- Preserve display/early display, DP, Wi-Fi, dual SIM SMS/data, battery and HiFi.
  Calls are outside the active task.
- Build uses tools/prepare-kernel.py and tools/build-source.sh. Boot packaging
  uses tools/cerro-build-boot.sh with local verified deployment inputs.
- Do not overwrite existing source trees or private backup files. No broad git
  reset/clean. Commit kernel changes in its own local git and refresh the public
  kernel patch/config hashes. Keep build artifacts out of commits.
- Before writing a phone, verify exact product/slot and preserve recovery. Never
  modify ABL/XBL/userdata without separate explicit scope. Current existing-phone
  switching preserves the same active slot and swaps only boot/dtbo; read its
  dedicated SWITCHING.md. Historical dual-slot recipes are not the current path.
- No private calibration, identifiers, phone numbers, raw logs, photos, tokens,
  firmware or partition images in public Git. Retain upstream licensing.
- Verify real function and normal cold boot, not merely active services/nodes.
  No masking/timers/login-time restart workaround as a completed fix.
- After every completed update: verify, document, commit and push. Use the owner's
  actual configured GitHub identity; do not add AI co-author/bot trailers. Do not
  rewrite upstream author notices or attribute external contributions to yourself.
- Every ~15 tool calls, before a flash and after context compaction, reread this
  contract and the current feature note. Three failures of one method require
  research and a different hypothesis before continuing.
