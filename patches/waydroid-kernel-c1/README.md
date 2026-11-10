# Waydroid kernel dependency closure (Cerro / SM8650)

The baseline already enables Binder IPC/Binderfs, memfd, PSI, namespaces,
seccomp and cgroups. The missing pieces were NAT/legacy-xtables configuration
and missing installed veth/bridge/conntrack/overlay modules.

`waydroid.fragment` uses the actual Linux7.2 symbols, including
NETFILTER_XTABLES_LEGACY and IP{,6}_NF_IPTABLES_LEGACY. Verify every requested
value after olddefconfig; unknown or unmet Kconfig options can disappear silently.
Use a normal in-tree `make modules` for in-tree kernel code after changing config;
`M=net` treated it as external and retained stale relative config dependencies.
Never silence unresolved modpost symbols.

NAT also changes built-in ICMP paths, so the tested plan relinks the Image and
builds its matching module closure. Keep PMIC GLINK and existing hardware configs
unchanged. The public kernel/cerro.config includes the options. The source-only
build remains independent of private boot/firmware inputs.

After a matching full build:

```sh
python3 patches/waydroid-kernel-c1/stage-modules.py build/linux-7.2 build/waydroid-modules
```

This strips debug only and stages all recursively declared module dependencies
with hashes/vermagic. It does not install, load, flash or reboot. Install only
against the matching boot kernel; retain a recoverable previous deployment.

Tests run as PID1 inside disposable namespaces, never the phone's original
network/mount namespace:

```sh
sudo unshare --mount --ipc --uts --pid --net --cgroup --fork --mount-proc \
  python3 patches/waydroid-kernel-c1/kernel-probe.py --overlay
sudo unshare --mount --ipc --uts --pid --net --cgroup --fork --mount-proc \
  python3 patches/waydroid-kernel-c1/network-probe.py
```

The core test allocates extra Binderfs devices (standard names may already be
created by the kernel), checks protocol8 and context-manager registration,
checks real parent/child shared memfd and seals, PSI/cgroup interfaces, and real
overlay copy-up. The network test creates private client/router/server networks,
a bridge and two veth pairs. The server has no return route to the client;
actual TCP+UDP responses must cross SNAT, and MASQUERADE plus DHCP CHECKSUM
packet counters must increase. It uses iptables-legacy, matching upstream
Waydroid's default network script. No host firewall rule or physical route changes.

Kernel acceptance is separate from a full Waydroid Android image, app UI,
GPU acceleration or Android camera integration. Runtime result is in
`docs/WAYDROID.md`; do not infer success from these source files existing.
