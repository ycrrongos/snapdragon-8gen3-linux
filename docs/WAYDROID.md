# Waydroid kernel support

Current stage: updated configuration/Image and24-module dependency closure
booted on Cerro. Isolated Binderfs/memfd/PSI/namespaces/overlay and real
TCP+UDP bridge/veth NAT with DHCP CHECKSUM packet counts passed. Normal
boot early display, main-camera full-resolution JPEG/release, dual-SIM restart
count0, HiFi speaker, battery and internal DRM remained intact.

The original kernel already has working Binderfs, Binder protocol8/context
manager operations, memfd shared mappings/seals, PSI and container namespaces.
The actual gap was NAT/legacy-xtables and missing installed module files.
See patches/waydroid-kernel-c1 for configuration, staging and isolated tests.

Linux7.2 uses NETFILTER_XTABLES_LEGACY and IP_NF_IPTABLES_LEGACY rather than
older config names. Waydroid's official network script prefers iptables-legacy
and needs MASQUERADE and CHECKSUM fill. No obsolete ashmem out-of-tree driver
is added: current Waydroid uses memfd when /dev/ashmem is absent.

The phone-specific boot build preserves the original rescue cpio source and
splices the exact already-validated daily+early-DRM cpio from its own DP6 boot
into the new image. The new source-only build separately compiles without that
private deployment input. No firmware/partition image/calibration is published.

References: [Waydroid driver setup](https://github.com/waydroid/waydroid/blob/db7294c4c2bd43157bab94cf8a3015e22d9f1ad8/tools/helpers/drivers.py),
[network script](https://github.com/waydroid/waydroid/blob/db7294c4c2bd43157bab94cf8a3015e22d9f1ad8/data/scripts/waydroid-net.sh),
[memfd selection](https://github.com/waydroid/waydroid/blob/db7294c4c2bd43157bab94cf8a3015e22d9f1ad8/tools/helpers/lxc.py),
[Binderfs documentation](https://docs.kernel.org/admin-guide/binderfs.html).

This kernel work does not claim full Android UI/app/GPU acceptance; that needs
a separately initialized Waydroid userspace and real application tests.

## Acceptance on Cerro

Kernel tree4c1705589; phone boot76ae5fbf, same activeB. New boot image
SHA18886d05c015d60d5daf15ac76485a48ac2c16f684d837253c77ebc8b0ce535a.
Android inactive-slot cache and both DTBO hashes were unchanged. Early DRM
fb0 ready at5.797s. The boot observation ran512s without reboot; a later
check at4963s still had the same boot, cellular restart count0 and no new
Oops/BUG/Call trace/DPU timeout.

Real GUI main-camera photos were4088×3072 and2044×1536; both sensor and
lens suspended on close and all four camera supply use counts returned0.
Battery reported87%/Charging; HiFi Speaker remained the default sink. These
are regression checks, not a new external-display hotplug or camera-quality claim.

All24 installed dependency modules were verified against the staging hashes.
The xt_tcpudp runtime match is explicitly included in addition to modinfo's
static dependency closure. Host switch scripts now default to this tested
image on an already provisioned phone; the image itself is not in Git.

Kernel interface acceptance is complete for this checkpoint. No full Waydroid
Android userspace has been initialized or claimed as tested.
