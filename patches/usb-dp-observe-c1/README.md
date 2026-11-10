# Passive USB-C PMIC GLINK RX observer

Debug-only, not installed for boot. Observes owners 32779/32780 through the existing exported client API. No TX, mux or hardware operations. UCSI synchronous replies are filtered; connection notifications and all PAN RX are logged. Logging callbacks run inside the parent client lock and do not sleep.

Build outside the kernel source (copy these two files to the M directory):

```sh
make -C build/linux-7.2 ARCH=arm64 LLVM=1 LOCALVERSION= M=/data/LOA_Nubia_Z60U/build/cerro-dp-observe modules
```

Copy the .ko over Wi-Fi to phone /tmp; verify matching SHA and vermagic; root `insmod /tmp/cerro_dp_observe.ko`. After capture: `/usr/sbin/rmmod cerro_dp_observe`. A temporary platform device/driver provides devm cleanup when unregistered. It never binds to the production altmode device.

2026-11-09: built and loaded successfully, SHA f4f647a935ab574174b64eb72e8a954f223cde3b86739cd53731a14bc1b60d19. Both registrations reported service UP. Physical replug produced UCSI events and PAN DP notifications with mux=2 / pin=3 / HPD=0, acknowledged by the existing production driver. See notes/features/20261109-dp-usbss.md. This is observability success, not DP output success.
