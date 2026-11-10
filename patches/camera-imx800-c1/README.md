# Cerro IMX800 V4L2 sensor work (camera bring-up in progress)

Native sensor driver for the IMX800 actually identified on this phone at
CCI0 master1, 7-bit0x10, ID0x0800. It uses the factory Cerro power sequence,
checks voltages and 24MHz MCLK, verifies chip identity, registers a single
2048×1152/30fps SRGGB10 mode, and synchronously powers off on probe and stream
stop. Exposure, frame length and analogue gain write actual registers under
group hold; no fake controls or lens/flash/OIS operations.

The source has compiled against the current DP6 7.2.0-rc5-dirty module ABI.
It has bound successfully and idles with zero regulator/clock votes after the
fixed one-shot driver was safely unbound on a fresh boot. It now produces actual RAW and software-ISP RGB frames at30fps with the
Cerro C-PHY graph. RGGB colour, focus movement and GUI JPEG capture have been
verified on real scenes. Normal cold-start integration and the remaining
image-quality/multi-camera work are still pending; see the feature note.

Register generation:

```
python3 patches/camera-imx800-c1/export-cerro-registers.py PRIVATE_CERRO_IMX800_BIN patches/camera-imx800-c1/imx800-cerro-regs.h
make -C build/linux-7.2 ARCH=arm64 LLVM=1 LOCALVERSION= M="$PWD/patches/camera-imx800-c1" modules
```

The exporter requires the exact known input SHA, validates the serialised
40-byte RegisterSetting records against the original CamX schema, refuses
other slave targets/non-byte writes/nonzero delays/stream-on, and validates
mode dimensions and line/frame lengths. The FP5 heuristic parser was useful
for discovery but read the wrong field as delayUs; it is not used to export
these tables. No raw proprietary blob or vendor implementation is included.

Mode7 was selected because it is the factory 30fps preview. Mode5 and mode8
are 240/480fps despite being small. Timing pixel rate is LL5520 × FLL13188 ×30;
OP link rate comes from the separate OP PLL, 24MHz/3×499/2=1.996Gsymbols/s.
The sensor's native analogue gain uses 16384/(16384-code), bounded to code
15360 (16x) in the stock implementation; this driver exposes native codes.
The reported crop includes factory ROI, 4×4 binning and digital crop72.

Runtime prototype shares the existing checked ID-overlay node's supplies and
GPIOs (`nubia,cerro-camera-id` match); permanent integration should use
`sony,imx800` and a regular board DT. Do not force-attach other I2C devices.
CCI1 must not retain its unused default GPIO13 pinctrl on this board.

Still required: C-PHY endpoints and SM8650/v2.2.0 CSIPHY plus CSID receiver
support, real bounded RAW capture, controls measured on raw frames, libcamera
soft ISP and usable GUI capture, then reopen/power release/cold-boot regression.
Installing this module or a camera GUI alone is not completion.

2026-11-10 actual Android IMX800 RAW/DNG reference confirms RGGB (CFA bytes
0,1,1,2); the initial BGGR declaration reproduced the reported red/blue swap.
The declaration is corrected consistently in format enumeration/get/size,
without changing sensor register tables or swapping channels in the GUI.
The earlier bring-up paragraphs below the introduction describe historical
checkpoints; current imaging evidence and remaining work are in the feature note.

The mode1 extension exposes4096×3072 with its own timing/crop/TRY format
and preserves mode7. Its API and low-mode regression are tested, but the
first high-mode STREAMON was correctly rejected by the earlier CAMSS guard
accepting only998MHz. The factory mode1 uses1GHz, the same3trios and settle25;
receiver acceptance and real high-mode imaging are tracked separately.

Mode1 now passes with the separate receiver whitelist patch: actual
4096×3072 RAW and4088×3072 RGB at30fps, real GUI autofocus/JPEG and
normal close. This is an imaging checkpoint, not Android quality parity.
