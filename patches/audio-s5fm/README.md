# audio-s5fm — actually ship patched WSA ko (s5fl was stale)

s5fl tagged OK but initramfs still had pre-patch `snd-soc-wsa884x.ko`
(nm only `gpiod_direction_output`). Rebuild forced `gpiod_direction_output_raw`.

Accept: gpio21/77 phys high; SWR enum non-zero; Attached. No paplay until then.
