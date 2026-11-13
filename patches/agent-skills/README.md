# Local skill policy overlay

Source: https://github.com/yzddmr6/android-mainline-port
Pinned installed base: 826fb98cd82fa87e61367d0827ddae9fc300d442 (MIT; retain upstream notices).

The installed user-level skill has local policy corrections. This patch records
those changes without vendoring the whole upstream skill. Apply only to that
base after checking `git apply --check`; on upstream update review/rebase the
patch rather than silently overwriting either version. The actual installation
is /home/rong/.agents/skills/android-mainline-port; no phone deployment occurs.
