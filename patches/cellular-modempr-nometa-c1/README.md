# cellular-modempr-nometa-c1

Rootfs-only Cerro cellular discriminant for the `cellular-modempr-c1`
hard-reset loop. It keeps the verified read-only `modem_pr` mount, rftrace,
remoteproc order, pdmap, RMTFS and every firmware/partition byte unchanged.

The only live target is:

- `/etc/systemd/system/cerro-cellular-meta.service.d/zz-cellular-modempr-nometa-c1.conf`

The drop-in replaces the known existing unit's `ExecStart` with `/bin/true`.
This keeps the dependency graph satisfied while preventing the previously
installed DMS `0x69` Meta_Build_ID sender from running during the next boot.
The installer gates on the exact known hashes of the unit, wrapper and helper,
writes only that drop-in, then performs `systemctl daemon-reload` and `sync`.
It does not start or restart any service, send QMI, touch remoteproc, mount a
partition, write qboot/EFS/any partition, or reboot.

A separately authorized single cold boot would compare whether stock RF
resource delivery still clears init failure without entering DMS
`shutting-down(5)` or the whole-device reset loop. Collection must remain
GET-only. Rollback is a separate action and is not implied by installation.

Run `./build.sh` to produce the deterministic `out/` bundle and manifest.
Building does not access or modify the phone.
