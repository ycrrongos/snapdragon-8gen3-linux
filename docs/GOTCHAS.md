# Tested Cerro constraints

- Keep the original boot chain. The tested path is stock ABL plus a custom header
  v2 Image with board DTB. Linux boot with Android DTBO left nonempty has failed
  at ABL; zeroing the active Linux DTBO is part of the current swap algorithm.
- The physical internal panel is BF068 / Raydium RM692H0,1116×2480 command-mode
  DSC. A different Visionox panel in vendor sources is not this tested panel.
- Built-in DTB assembly reads arch/arm64/kernel/sm8650-nubia-cerro.dtb, not only
  the compiled boot/dts copy. Update both before relinking an Image. The current
  setup.c does not reinstate the historical early built-in-DTB injection hack.
- Preserve module ABI/config. Changing PMIC GLINK from module to built-in broke
  previously installed battery/UCSI modules. Runtime provider ordering matters.
- Never direct default boot logs to ttyGS0. Writes with no host can stall init;
  ACM gadget/getty should still exist. Logging is an explicit cmdline opt-in.
- Internal power-key behavior uses the existing PowerDevil turn-off-screen/wakeup
  path. Do not write brightness=0 or install the retired cerro-dpms helper.
- A GPU/display lifecycle bug required releasing old command-mode resources;
  DP link validation must use real link bandwidth, independently of wide pixel
  bus mode. Passing one mode is not proof of safe repeated switching/hotplug.
- Cameras: CAMCC supplier first, complete graph before CAMSS first probe. Do not
  remove/reapply the board overlay or rebind after login as the daily solution.
  IMX800 is RGGB here; compare actual RAW/DNG before channel-swapping a GUI.
- Factory link timing and C-PHY rates differ by sensor mode. Preview mode uses
  998MHz and full12MP uses1GHz; both use the audited3-trio receiver path. No
  arbitrary frequency guard removal is implied.
- Lens calibration belongs to each unit. Compilation uses no EEPROM data; startup
  validates that unit's protected calibration file. OIS is separate from focus.
- Audio/user sessions must wait for real remote-processor/sound-card dependencies.
  Timers, masked services and login-time restarts are not completed integrations.
- Detect USB mode before diagnosis: 05c6:9008 EDL,18d1:d00d fastboot,
  19d2:0112 MemoryDump,1d6b:0104 Linux gadget. Dump is not EDL. Rediscover DHCP
  after reboot and compare boot ID; black screen or an old IP timeout is not hang.
