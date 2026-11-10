# Cerro native camera startup

The normal `multi-user.target` unit loads CAMCC and verifies its driver binding,
registers the native sensor/lens drivers, installs the complete board graph,
initializes CCI, then loads CAMSS and waits for the actual media graph. The
private unit EEPROM snapshot lives in `/var/lib/cerro-camera` (0700/0600) and
is verified before use. No firmware/EEPROM writes are performed.

This replaces the old `After=graphical.target` service, whose first CAMSS probe
preceded the runtime graph and needed a later sensor/CAMSS rebind. The managed
module blacklist remains to prevent udev bypassing the real hardware order;
the service stays on the normal boot target, with no timer, restart, masking
or login-time recovery. Existing CCI1 with no clients may be released before
installing its corrected pinctrl; actual master0 is retained for the ultrawide.
The camera sensor and CAMSS are not rebound after a failed probe.

Install **on the handset as root**, using the verified calibration file read
from that same unit and its expected full SHA:

```
bash install-on-phone.sh PRIVATE_EEPROM64 EXPECTED_SHA256
```

The installer preserves the previous unit and modprobe configuration in
`/usr/local/share/cerro-backups/camera-startup-20261110`, validates the unit,
and enables the same service for multi-user boot. It intentionally does not
start it against an already populated runtime graph. Validate with a normal
reboot, first-probe journal ordering, real photos, rail release and regressions.

Actual cold boot7459031c: started28.112s, graph installed28.346s, CAMSS loaded
afterwards, actual sensor/lens/media graph ready28.452s. The12MP GUI captured
real4088x3072 and2044x1536 JPEGs and exited normally, both devices suspended,
four rails use_count0. Over510s of the same boot and cellular/HiFi/remoteproc
regressions passed. This verifies startup and imaging, not final autofocus
quality, Android image-quality parity, other lenses or the final chosen UI.
See `notes/features/20261110-camera-startup.md`.
