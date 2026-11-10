# ModemManager 1.24 DSDS primary-slot identity

Current Cerro exposes physical slot1/logical1 and slot2/logical2 as ACTIVE.
UIM file reads use Primary-GW provisioning, but upstream 1.24 selects the
last ACTIVE slot as primary. With different ICCIDs it detects a SIM change
on every enable and continually destroys/recreates the modem.

This patch selects the lowest valid active logical subscription, independent
of physical array order, preserving both active SIM objects. It only fixes
primary identity discovery. It does **not** implement secondary subscription
NAS/WMS/WDS binding or claim complete dual-SIM support.

Source: Debian modemmanager 1.24.0-1+deb13u1, including its existing Fibocom
patch. Source archives:

- `modemmanager_1.24.0.orig.tar.xz`: SHA256 `63ded4c0f3936bb0db5ae35ef1dfd57c5d5b4dd8a5cdaa7fb2182255218c9168`
- `modemmanager_1.24.0-1+deb13u1.debian.tar.xz`: SHA256 `0362e74213576b3f830b344f139407843a6caf6b9ae892c5a085a340da6999f2`

Download from Debian pool `/debian/pool/main/m/modemmanager/` through FlClash,
verify hashes, unpack upstream as `mm-src/`, unpack Debian tar there, apply
`debian/patches/series`, then this patch with `patch -p1`.

`prepare-build-sysroot.sh` **downloads only** build dependencies and extracts
them under `/home/user/cerro-mm-build/sysroot`; it does not install/upgrade
system libraries. Place patched `mm-src` or `mm-src.tar` in that directory.
Run `python3 link-build-runtime.py` to expose already-installed runtime
SONAMEs where dev package symlinks lack their target, then `build-on-phone.sh`.
If configured before these links exist, rerun meson setup with
`--reconfigure --clearcache` to discard cached static-library selection.

Before deployment remove the build RUNPATH with `patchelf --remove-rpath`.
Audit `readelf -d`, on-phone `ldd` (no build paths/missing libraries), and
`--version`. Current candidate SHA256 is
`d40eeda4cdb7d4dd36dc07da51bb19877bf03c8c55496e8de0ba302a59629ece`.
`install-candidate.sh PATH SHA256` installs only this daemon and its precise
ExecStart drop-in; it does not restart services. Restart only ModemManager
after checking the active experiment. Preserve the distro daemon/libraries/plugins.
Rollback removes only `/etc/systemd/system/ModemManager.service.d/zz-cerro-primary-slot-c1.conf`,
daemon-reloads and restarts ModemManager.

`test-primary-slot.py SOURCE` compiles the actual selector against libqmi's
slot structs. Original source fails 4/9 cases; patched source passes 9/9.
The cases include Cerro DSDS, reversed logical mapping, three subscriptions,
no/single active card, and invalid logical ID. Runtime verification remains
required; tests alone do not prove SMS/data.
