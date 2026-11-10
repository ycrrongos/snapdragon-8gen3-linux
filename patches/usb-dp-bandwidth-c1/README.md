# DP link bandwidth validation

Cerro DP5 let the HDMI adapter select RGB 3840x2160 at 60Hz (537300kHz) on two HBR2 lanes. Its 8640000kbit/s payload budget is below even RGB 18bpp (9671400kbit/s). The adapter showed no signal; changing only to 1080p60 produced a visible desktop.

`mode_valid` reused the pixel clock halved for the internal wide bus when calculating wire bandwidth. This patch separates the interface-clock limit from transmitted pixel rate. Only supported YUV420 halves wire pixel data. It also rejects 420-only modes without VSC support and uses candidate-independent wide-bus capability. Direct four-lane 4K60 remains valid.

Run `python3 patches/usb-dp-bandwidth-c1/test-mode-valid.py` from the repository root. The test compiles the **actual current C functions** with minimal transport stubs (normal video, no compliance bpp override); the old source fails three of ten cases, the fixed source passes all ten. It also checks 4K30/1080p, wide/narrow interface clocks, and 420 support. This does not replace hardware tests.

Kernel parent 9b6770afd; candidate 7b732bdca. Object/full boot builds passed; the deployed DP6 filtered the over-budget RGB 4K60 modes on the two-lane adapter. HDMI 4K30 output, nine display-state transitions and a physical unplug/replug were confirmed with no DPU errors. Direct four-lane HBR2/4K60/30bpp also passed nine state transitions and operator confirmation. Full 510s observation completed, with no DPU timeout/Oops in the deployed DP6 boot. Packaging must retain the known early-DRM cpio and opt-in ACM logging. Details: notes/features/20261110-dp-modeset.md.

Relevant upstream implementation/review context:
- https://git.zx2c4.com/laptop-kernel/commit/drivers/gpu/drm/msm?id=bd926e62d355879133452bc3889447f8e89757f2
- https://www.mail-archive.com/dri-devel%40lists.freedesktop.org/msg622957.html
