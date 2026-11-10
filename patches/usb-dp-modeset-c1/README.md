# DPU command-mode teardown experiment

Backport of Xi Zhang resource-cleanup v2 patches 2/6 and 3/6, as one dependent cleanup fix.

- https://lists.openwall.net/linux-kernel/2026/10/26/2651
- https://lists.openwall.net/linux-kernel/2026/10/26/2653

Cache the LMs owned at mode_set before invoking the full cleanup from CMD disable. This avoids clearing the newly swapped resources (or dereferencing an encoder CRTC after disconnect), and releases the old DSC/LM/interface state before its CTL is reused by DP. Other patches in the series are intentionally outside this experiment.

Kernel parent: 6e5332b110683133110819b065347d98bc236311. Experiment tree: 9b6770afd (full SHA in feature notes). Both touched objects compile. DP5 direct output was operator-confirmed; nine state transitions had no DPU errors. HDMI 1080p output and nine transitions plus a 48.72s external-only dwell also passed after isolating a separate link-bandwidth bug. DP6 retains this cleanup and has also passed HDMI 4K30 transitions/hotplug. This is a candidate fix, not evidence that DP is complete. See notes/features/20261110-dp-modeset.md.
