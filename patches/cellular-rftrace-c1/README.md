# cellular-rftrace-c1

Rootfs-only Cerro cellular diagnostic candidate. It is intentionally not a
boot image and does not contain or invoke any partition flashing tool.

## Purpose

- build from the exact Debian trixie `rmtfs` 1.1-4 and `tqftpserv` 1.1-4
  source archives;
- fix the inverted `GET_DEV_ERROR` caller validation in `rmtfs`;
- initialize the malformed-IOVEC response locals so a decode error cannot
  reach `storage_sync()` with undefined state (valid requests are unchanged);
- retain the existing behavior of RMTFS messages 1-4;
- record bounded request metadata only (paths, directions, sector ranges,
  offsets and QMI results), never EFS/TFTP payload bytes;
- preserve `/usr/bin/rmtfs` and `/usr/bin/tqftpserv` for simple rollback.

The binaries are statically linked for AArch64 Linux with the AOSP musl
toolchain. `rmtfs` uses the same `/dev/qcom_rmtfs_mem1` and
`/sys/class/rmtfs/qcom_rmtfs_mem1/{phys_addr,size}` ABI already present on the
phone. `tqftpserv` retains Debian's `/lib/firmware` and `/tmp/tqftpserv`
mappings; this candidate does not mount or expose `persist`.

## Build

The verified Debian source archives are kept under `sources/`. The build also
uses the local AOSP QRTR library source, Zstandard source, and AArch64 musl
sysroot. Their input hashes are emitted into the output audit file.

```sh
patches/cellular-rftrace-c1/build.sh
```

Outputs are written to `out/`. The build runs twice in separate temporary
directories and requires byte-identical binaries before publishing the final
bundle.

## Intended live scope (not authorized merely by building)

The installer adds only:

- `/usr/local/libexec/cerro-rmtfs-rftrace-c1`
- `/usr/local/libexec/cerro-tqftpserv-rftrace-c1`
- `/etc/systemd/system/rmtfs.service.d/zzz-cerro-rftrace-c1.conf`
- `/etc/systemd/system/tqftpserv.service.d/zzz-cerro-rftrace-c1.conf`

It performs `systemctl daemon-reload` but does not start, stop, restart, enable
or disable a service and does not reboot. A separately authorized cold reboot
is required to exercise it. Existing writable RMTFS policy remains `-P -s`;
the only added runtime option is `-v`.

Trace files on the Debian root filesystem:

- `/var/log/cerro-rmtfs-rftrace-c1.log`
- `/var/log/cerro-tqftpserv-rftrace-c1.log`

No qboot, boot-chain, dynamic partition, persist, EFS restore, modem setter or
remoteproc-only restart operation is part of this candidate.
