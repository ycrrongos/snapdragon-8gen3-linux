# Cerro native camera board graph (runtime checkpoint)

Consolidates the already tested sensor/rail/C-PHY endpoints/lens into one
runtime graph. It does not rebuild Image or alter boot partitions. The module
uses current live OF providers (CAMCC/TLMM/CCI1-master0 pinctrl), validates their
identity, patches typed property placeholders and requires explicit per-unit
OTP focus bounds. Never hard-code post-overlay regulator phandle344.

`build.sh` compiles the FDT and external module against the same module ABI.
`load-runtime.sh` is specific to the identified unit (EEPROM64B hash and112..<per-unit-focus>
bounds), checks no CCI1 I2C clients before releasing its unused master1 GPIO13
claim, applies the board graph once and rebinds CCI1 with master0 retained for
the future ultrawide. Do not remove/reapply OF overlays.

The runtime test on bootb32c5140 succeeded with moduleb8bc2acc… and unchanged
IMX800/lens/CAMSS drivers. Since CAMSS had already probed with the old endpoint-
less DT, its notifier required a one-time sensor-unbind → CAMSS-unbind/bind →
sensor-bind for this experiment. This is NOT a daily solution: cold-start
integration must place the board graph before the first CAMSS probe.

No startup service is installed yet. After reboot the graph still disappears.
Real paired RAW+RGB3frames/30fps were received and all camera rails returned
zero after closing. See the feature note for exact hashes and open work.
