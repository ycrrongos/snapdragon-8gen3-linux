# cellular-ipa-init-stats-size-c1

## Bug
In `ipa_qmi.c` `init_modem_driver_req()`, mainline sets:

- `hw_stats_quota_size = ipa->mem_offset + mem->size`
- `hw_stats_drop_size  = ipa->mem_offset + mem->size`

Sibling field `modem_mem_info.size` correctly uses `mem->size` only.
`*_base_addr` correctly uses `mem_offset + offset`. The size fields
look like a copy-paste error and may confuse modem IPA init on SM8650.

## Fix
Use `mem->size` for both size fields.

## Install
Replace `/lib/modules/7.2.0-rc5-dirty/kernel/drivers/net/ipa/ipa.ko`, then
**hard power-cycle** (soft reboot hangs on cerro IPA STOP). Do not
`rmmod ipa`.
