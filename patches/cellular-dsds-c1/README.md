# Cerro independent dual-subscription QMI work

These probes keep ModemManager's primary client separate. `qmi_socket.py`
creates one QRTR socket per QMI client, discovers endpoints, matches replies,
and rejects malformed TLVs. Identifiers and message content stay in memory.

Confirmed interfaces (independent sockets, not persistent modem NV settings):

- NAS bind: 0x45, TLV1 uint8 zero-based.
- WMS bind: 0x4c, TLV1 uint8 zero-based; GetBinding0x58/TLV10.
- DMS bind: 0x54, TLV1 uint32 one-based; GetBinding0x55/TLV10.
- WDS bind: 0xaf, TLV1 uint32 one-based; GetBinding0xb0/TLV10.
- DSD GetCurrentDDS: 0x4f/TLV10 uint32 one-based; SwitchDDS0x4e,
  TLV1 uint32 subscription, TLV10 uint32 type (0 permanent, 1 temporary).

Sources: Chromium's original Qualcomm Gobi API structs/enums in
`gobi-api/GobiAPI_2013-07-31-1347`, official libqmi message JSON, and
[modern DSD IDL](https://github.com/comprehensive9/vendor_qcom_proprietary/blob/master/qmi/data/data_system_determination_v01.h)
plus its matching generated C encoding. Local reference downloads are ignored
build artifacts; proprietary source is not copied into this patch directory.
The old NAS SetDualStandbyPreference0x4b setter returns NotSupported on Cerro;
do not retry it. DSD GetCurrentDDS has been verified against the running modem.

Both subscriptions are USIM ready and NAS registered. User confirmed hardware
repair and both cards inserted, and authorized mutual SMS using their own
MSISDNs. `test-mutual-sms.py --send-mutual-tests` is deliberately explicit:
normal imports send nothing, and no send is retried on a timeout. It verifies
two distinct local numbers and binding, changes only ordinary SMS class-none
to ME store-and-notify (preserving other classes), sends short uniquely tagged
UCS2 tests, and requires matching sender/content on the other subscription.
It leaves received messages intact. On this firmware ListMessages needs a tag;
InvalidIndex47 for an empty tagged list is treated as empty. Both international
and domestic numeric originating addresses are supported. The first 1→2 test
was initially missed by the domestic-address parser; it was subsequently
verified in its original stored record, without another send. Reverse 2→1 also
passed. `test-sms-pdu.py` checks synthetic encoding/decoding and rejection cases.

Data work: SIM1 has independently bound HTTPS verification with IPA EP24.
The key WDS probe correction is to bind the subscription **after** BindMux and
SetIpFamily: the running firmware changes the subscription from 2 to 255 in
BindMux. Always verify GetBindSubscription==2 immediately before and after
StartNetwork; otherwise a returned IP can belong to the primary subscription.
`test-sim2-data.py` performs a bounded secondary call and restores original
DDS1 and the existing NM profile in finally. It is a probe, not a daily data
service. The daily service described below owns persistent operation.
`observe-qmap.py` records only packet direction, QMAP flags/mux/length/counts.

No calls, IMS, RAT/band forcing, SIM power-off, EFS rollback, or kernel change
is part of these probes. Current results and limitations are in
`notes/features/20261110-dual-sim-data-sms.md`.

SIM2 data subsequently passed with an independent carrier IP, device-bound TLS
responses from two hosts, and actual interface RX growth. A second probe bug
was missing RMNET checksum flags: IPA reports MAPv5 for TX/RX, while a plain
`ip link add type rmnet` omits those headers. Match the working MM link's
`ingress-deaggregation`, `ingress-mapv5-checksum`, `egress-mapv5-checksum`.
The public MM `get_rmnet_device_add_link_flags()` derives them from
`/sys/devices/platform/soc@0/3f40000.ipa/feature/{tx,rx}_offload`.
Each temporary secondary test restores DDS1 and the working SIM1 NM profile.
Temporary probes alone are insufficient; use the daily entry and reboot verification below.

## Daily entry

`install-daily-entry.sh PATCH_DIRECTORY REPO_TOOLS_DIRECTORY` installs the
existing Before=MM USIM prerequisite chain, an owner-only local socket service,
and the GTK application **SIM 与短信**. It daemon-reloads/verifies but does not
start/enable the service; enable `cerro-cellular-c1.service` after active-card
gates. The daemon uses the proven WDS sequence, keeps the selected secondary
call alive, and delegates IP/DNS/routes to NM's generic `cerro-sim2-ip` profile.
It reads IPA's actual MAPv4/v5 offload attributes rather than assuming plain
QMAP. Wi-Fi retains priority. Selected SIM/off state is stored privately and
applied only after real MM modem initialization; no boot timer or late target.
The primary NM profile's autoconnect follows the user's selected data card,
so selecting SIM2/off cannot be undone by SIM1 automatically reconnecting.

The local API socket is mode0660 root:user and validates SO_PEERCRED against
root/current phone owner. It exposes only status, SMS list/send, and data-slot
selection, with bounded JSON requests and no arbitrary executable/command API.
No TCP listener, shell interpolation, device identifiers in logs, or outgoing
automatic test SMS. Incoming SMS remain in modem storage; user-created sent
history is private in `/var/lib/cerro-cellular-c1`.
The GUI supports choosing either sender/data SIM, numeric/service senders,
GSM7/UCS2 decoding and concatenated text messages. Codec tests are synthetic;
the actual two-direction short Chinese tests were separately verified.

Verification: user API sees both registered cards/two received tests, API
select2→bound TLS200→select1→bound TLS200 passes, and real Wayland window/card/
message pages map. Both cards separately passed DNS and bound HTTPS with Wi-Fi
disabled through NM, restored in finally over independent USB ACM.
The corrected cold path now reaches first READY with NRestarts=0 and restores
saved SIM2 data; the full observation record and completion status are in the
feature note. `api_client.py` prints only redacted metadata.

## Cold data-port and network dependencies

An attached NAS subscription does not imply a configured IPA data port or a
ready CM packet-data service. Hot tests hid two missing dependencies because
a preceding MM/SIM1 bearer had already set them up:

- DPM OpenPort hardware ports (service47/message0x20/TLV0x11): embedded4,
  interface1, RX/TX from actual IPA tx/rx sysfs (crossed from the modem view).
- WDA raw-ip plus the IPA's reported MAPv4/v5 TX/RX format. Read back before
  starting the WDS call; reuse a matching format. Aggregation limits match
  MMPortQmi's IPA path. Official schemas are
  [DPM](https://github.com/linux-mobile-broadband/libqmi/blob/main/data/qmi-service-dpm.json)
  and [WDA](https://github.com/linux-mobile-broadband/libqmi/blob/main/data/qmi-service-wda.json).
- WDS StartNetwork can explicitly reject initial attachment with CallFailed14,
  end3, verbose(type3,reason2001)=CM_NO_SERVICE even after NAS reports attached.
  Only this confirmed no-call response is retried, on the same bound client,
  for at most90s. An APN/auth rejection, other code, lost subscription or an
  unknown timeout outcome fails immediately. No service restart, boot timer,
  SIM1 warmup, or hidden fallback/selection overwrite is used as readiness.

`test-data-port.py` decodes actual DPM/WDA requests and tests readback/reuse.
`test-start-network.py` covers transient recovery versus permanent/unknown
outcomes, deadline and lost subscription. `test-boot-dependencies.py` tests
PS attachment and preserving saved selection on initialization failure.
`test-wifi-independent.py IFACE` is an **ACM-only acceptance test**: it requires
a configured UDC, temporarily disables Wi-Fi, invokes the staged
`/tmp/test-bound-data.py`, and re-enables Wi-Fi in finally. Do not invoke this
through the Wi-Fi SSH connection it will deliberately interrupt.

Prerequisites remain separate validated packages: RF provider/nometa,
cellular-qmi-primary-slot-c1 ModemManager, and cellular-ipa-wan-ep-c1 IPA EP24.
This directory does not install a new boot image or replace those packages.
