# audio-s5fk — WSA SD_N pinctrl output-high

## Why
s5fj: Pulse/`paplay` OK but user hears silence. WSA884x on `6b10000` both
`UNATTACHED` + `SWR CMD error`. Left LPASS gpio21 stuck `out 0`; downstream
`spkr_*_sd_n_active` uses **output-high** (physical HIGH = out of SD_N shutdown).

## Change
- `spkr_1_sd_n_active` / `spkr_2_sd_n_active`: `output-low` → `output-high`
- Tag `cerro_dtb=s5fk`

## Accept
Cold boot: both `sdw:1:0:0217:0204:00:{0,1}` **Attached** (or at least one);
gpio21/77 physical high. **Do not paplay until Attached.**
