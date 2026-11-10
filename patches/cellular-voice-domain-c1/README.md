# cellular-voice-domain-c1

Allow setting QMI NAS voice domain preference from CLI (stock `qmicli` cannot).

## Why

Cerro MO voice calls stay in QMI `origination` / MM `dialing` with `mode=lte` then terminate.
Voice domain was `ps-preferred` (VoLTE). Forcing `cs-preferred` / `cs-only` still reports `mode=lte`
and does not reach `active` — Unicom path is VoLTE; **IMS registration is the real blocker**, not CSFB.

This patch is still useful to experiment with domain preference without rebuilding full Telephony.

## Usage (on phone)

```bash
# built binary kept at /home/rong/bin/qmicli-cerro
/home/rong/bin/qmicli-cerro -d qrtr://0 \
  --nas-set-system-selection-preference=voice-domain=cs-preferred
# values: cs-only | ps-only | cs-preferred | ps-preferred
```

## Evidence (2026-10-21)

- Set `cs-preferred` / `cs-only` → NAS+VOICE config reflect it after disable/enable.
- Dial 10086 still: `origination` + `mode=lte` → terminated (~45s). No `active`.
