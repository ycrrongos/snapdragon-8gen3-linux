# audio s5fg — persist CERRO tplg + default WSA route

## Changes
- Embed `SM8650-CERRO-tplg.bin` in initramfs → copy to rootfs
- `cerro-audio-up.sh`: after card up, apply WSA MultiMedia1 mixer route
  (RX MUX AIF1_PB, INP RX0/RX1, Spkr DAC/PA unmute)
- DTS `cerro_dtb=s5fg`

## Playback note
Use `speaker-test -D hw:0,0 -c 2 -r 48000 -F S16_LE` (not plughw).
`plughw` previously returned -EINVAL; with route, hw:0,0 completes L/R periods.
SWR CMD errors on WSA controller may still mean no audible speaker until ports fixed.
