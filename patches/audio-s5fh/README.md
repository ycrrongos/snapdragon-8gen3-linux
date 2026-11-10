# audio s5fh — wait for ALSA card before WSA route

## Why
s5fg embedded tplg + route, but `cerro-audio-up` only `sleep 5` then checked cards.
On device: `cards=--- no soundcards ---` at ~54s/65s; SoundWire/ASoC card appears later →
boot route skipped → `speaker-test` returns `-EINVAL` until mixer is set by hand.

## Fix
- Poll up to 90s for `SM8650CERRO` in `/proc/asound/cards`, then apply WSA MultiMedia1 route
- Digital volume max is 81 (not 84)
- `TimeoutStartSec=180` on `cerro-audio.service`
- DTS `cerro_dtb=s5fh`
