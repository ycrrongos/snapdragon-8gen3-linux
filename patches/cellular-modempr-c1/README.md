# cellular-modempr-c1

Rootfs-only Cerro cellular candidate that exposes the verified stock
`modem_a:/image/modem_pr` tree at the local path used by Debian `tqftpserv`:
`/lib/firmware/qcom/sm8650/modem_pr`.

The service runs before `cerro-remoteproc-prepare.service`, therefore before
`qcom_q6v5_pas` starts MPSS. It mounts only `modem_a` with
`ro,nosuid,nodev,noexec`, exposes only the `modem_pr` subtree through a fixed
symlink, and verifies all 196 files against a deterministic aggregate SHA-256.
Any missing file, hash mismatch, unexpected symlink, mount, or mount option
causes the service to fail and blocks remoteproc preparation.

Run `./build.sh` to produce `out/` and its manifest. Building does not access
or modify the phone.

## Intended live install scope

The installer writes only:

- `/usr/local/libexec/cerro-modempr-c1`
- `/etc/systemd/system/cerro-modempr-c1.service`
- `/etc/systemd/system/cerro-remoteproc-prepare.service.d/zz-cerro-modempr-c1.conf`
- `/lib/firmware/qcom/sm8650/modem_pr` as an exact symlink to
  `/run/cerro-modempr-c1/image/modem_pr`

It then performs `systemctl daemon-reload` and `sync`. It does not mount
anything, start or restart a service, restart remoteproc, send QMI setters, or
reboot. A separately authorized cold reboot is required to exercise it.

At runtime the only persistent partition exposed is `modem_a`, and it is
mounted read-only. The candidate does not mount `persist`, write qboot or any
partition, copy firmware payloads into the root filesystem, or roll back EFS.
The existing `cellular-rftrace-c1` diagnostics remain unchanged so the first
successful and follow-on TQFTP requests can be observed.

