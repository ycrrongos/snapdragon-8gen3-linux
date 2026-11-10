# audio s5fj — KDE Pulse sink + MultiMedia2 speakers

## Problem
KDE saw no output: Pulse card profile `off` (stereo-fallback available:no),
PipeWire empty (Pulse owns ALSA). No SM8650-CERRO UCM. Speakers need MultiMedia2 + BOOST/PBR.

## Fix
- UCM `SM8650-CERRO` (speaker-only HiFi → `hw:0,1`)
- `cerro-audio-session.sh`: load `module-alsa-sink` `cerro_speaker` on hw:0,1, set default
- user systemd + XDG autostart
- kernel mixer route switched to MultiMedia2 + BOOST/PBR
- DTS `cerro_dtb=s5fj`
