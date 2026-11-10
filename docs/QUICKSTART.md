# Agent onboarding

Read AGENTS.md, docs/STATUS.md, kernel/source.lock.json and docs/BUILDING.md.
Build first with `make prepare && make build`; use `make test` for host logic.
Do not begin by flashing, replacing services or running all installers.

Find the in-tree delta in kernel/cerro.patch. External camera drivers are
patches/camera-imx800-c1 (sensor), camera-optics-c1 (actuator) and camera-board-c1
(runtime graph). The normal dependency loader is camera-startup-c1. Soft-ISP
and GUI changes are camera-userspace-c1 and camera-gui-c1. Cellular checkpoint
code is cellular-dsds-c1, with memshare and the IPA delta in the kernel patch.
Display changes are in the complete kernel patch; snapshots are historical.

Create a feature note with the exact intended variable, falsifier, scope,
rollback path, input hashes and required regressions. Research Linux primary
sources and sibling ports before changing hardware behavior. Keep private
calibration/runtime state out of source and logs. Record facts separately from
hypotheses. Three failures of the same method mean research and a new method.

For a new phone, establish product/board/boot topology and an existing unlocked
boot path, lawful firmware sources and backups before writes. Never copy a
Cerro flash recipe across devices by changing only the DT model string.
