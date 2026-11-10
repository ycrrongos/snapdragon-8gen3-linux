# cellular-ipa-gsi-stop-c1

## Symptom
On cerro (SM8650 / IPA v5.5), bringing cellular data up then suspending or
disconnecting produces:

- `ipa: GSI command 2 for channel 1 timed out, state 4` (STOP, STOP_IN_PROC)
- `error -11 suspending channel 1`
- modem fatal `ipa_hal.c:… GSI_STATUS_SUCCESS failed`

Channel 1 is AP_MODEM_RX (endpoint 23) per `ipa_data_v5_5`.

## Fix
Force-close open aggregation on RX endpoints before GSI STOP/suspend, and
increase STOP retries. Does **not** by itself fix RX=0 (separate datapath).

## Apply
Against `build/linux-7.2` (or matching 7.2.0-rc5 tree):

```bash
patch -p1 < patches/cellular-ipa-gsi-stop-c1/0001-ipa-force-close-aggr-before-rx-stop.patch
```
