# stability-adsp-serialize-c1

> **2026-10-20 superseded for audio bring-up.** Gating `cerro-audio` on
> `cerro-cellular-prepare` (UIM/GW) fixed the PAS race only by delaying audio
> until after SDDM/PipeWire had already raced the missing card, then needing
> `cerro-audio-bootfix` to restart PipeWire. That path is forbidden by
> `AGENTS.md` §5.2. Replacement: wait for MPSS `running` inside
> `cerro-audio-up.sh`, keep audio on `multi-user` + `Before=sddm`, and make
> SDDM `After=cerro-audio` / `sound.target`. Remove
> `zz-stability-adsp-serialize-c1.conf` on live images.

Rootfs-only Cerro stability discriminator for the repeated whole-device reset
at the ADSP remoteproc start edge. The last twelve retained boots all end at
`cerro-audio: starting adsp (fw ready)` while the modem and ADSP are both still
offline. The effective units currently allow the audio script to start ADSP in
parallel with RMTFS, PD mapper, MPSS boot and UIM preparation.

The only live target is:

- `/etc/systemd/system/cerro-audio.service.d/zz-stability-adsp-serialize-c1.conf`

The drop-in adds `Wants=` and `After=` on
`cerro-cellular-prepare.service`. That service can finish only after QMI UIM
proves MPSS is responsive, so the existing audio script does not write `start`
to the ADSP remoteproc until the modem startup path has completed. The audio
script, cellular services, modem firmware, ADSP firmware and all partition
bytes remain unchanged.

The installer gates on the exact live hashes of the audio unit/script,
remoteproc unit, cellular-prepare unit/script and existing no-meta drop-in. It
writes only the one drop-in, then runs `systemctl daemon-reload` and `sync`. It
does not start/restart a service, touch remoteproc, send QMI, create a bearer,
mount a partition, write qboot/EFS/any partition, or reboot.

The first subsequent natural cold boot can test the new ordering without an
extra host reboot request. Success requires a new boot to survive materially
longer than the prior loop while retaining registered cellular, running ADSP,
the ALSA card and KDE audio. Rollback is a separate action and is not implied
by installation.

Run `./build.sh` to produce the deterministic `out/` bundle and manifest.
Building does not access or modify the phone.
