#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import asyncio
from asyncio.exceptions import TimeoutError, CancelledError
import argparse
import logging
from pathlib import Path
import signal
import sys

from statemachine import State, StateMachine

from .data import SimState, PLMN, ConfigInfo, ConfigId, cfg_id_to_str, cfg_str_to_id, imsi_to_plmn
from .config import Config
from .common import SimcardError, SimcardMissing, InvalidImsi, InvalidUri, PdcError, QmiTimeout, QmiError, get_tlv_value
from .services import *

import gi
from gi.events import GLibEventLoopPolicy

gi.require_version('Qmi', '1.0')
gi.require_version('Qrtr', '1.0')
from gi.repository import GLib, Gio, Qmi, Qrtr

LOG = logging.getLogger()

# Set up the GLib event loop
POLICY = GLibEventLoopPolicy()
asyncio.set_event_loop_policy(POLICY)
LOOP = POLICY.get_event_loop()

IMSD = None

# FIXME: move this into config/argument parsing
def log_handler(ctx, level, message):
    LOG.debug(f"{ctx}: {message}")

def enable_qmi_logging(tracing: bool = True, private: bool = True):
    mask = \
        GLib.LogLevelFlags.LEVEL_CRITICAL |\
        GLib.LogLevelFlags.LEVEL_INFO |\
        GLib.LogLevelFlags.LEVEL_MESSAGE |\
        GLib.LogLevelFlags.LEVEL_WARNING |\
        GLib.LogLevelFlags.LEVEL_DEBUG |\
        GLib.LogLevelFlags.LEVEL_ERROR
    # glib.log_set_handler(None, level_mask, log_handler)
    GLib.log_set_handler("Qmi", mask, log_handler)

    Qmi.utils_set_traces_enabled(tracing)
    Qmi.utils_set_show_personal_info(private)

class OpenIMSD(StateMachine):
    # StateMachine
    ## The successful flow through the states:
    st_initial = State(initial=True)
    st_read_config = State()
    st_connect_modem = State()
    st_get_imsi = State()
    st_disable_imsd = State()
    st_configure_imsd = State()
    st_wait_events = State()

    ## uncommon states:
    st_wait_for_modem = State()
    st_wait_for_usim = State()

    ## st_failed is the final state and exit the daemon
    st_failed = State(final=True)

    # Events
    e_start = st_initial.to(st_read_config)

    ## config state
    e_config_valid = st_read_config.to(st_connect_modem)
    e_config_invalid = st_read_config.to(st_failed)

    ## Connect Modem
    e_modem_connected = st_connect_modem.to(st_get_imsi)
    e_modem_missing = st_connect_modem.to(st_wait_for_modem)
    e_modem_found = st_wait_for_modem.to(st_connect_modem)

    ## Get IMSI
    e_imsi_read = st_get_imsi.to(st_disable_imsd)

    e_disabled_imsd = st_disable_imsd.to(st_configure_imsd)

    ## Wait Events
    ## TODO: is there a simpler way to express this?
    # When PDC changes, similar to e_usim_missing, but we will re-do the disable and enable loop
    e_pdc_config_change = \
        st_disable_imsd.to(st_get_imsi) | \
        st_configure_imsd.to(st_get_imsi) | \
        st_wait_events.to(st_get_imsi)

    e_usim_missing = \
        st_connect_modem.to(st_wait_for_usim) | \
        st_get_imsi.to(st_wait_for_usim) | \
        st_configure_imsd.to(st_wait_for_usim) | \
        st_wait_events.to(st_wait_for_usim)

    e_config_change = \
        st_read_config.to(st_read_config) | \
        st_connect_modem.to(st_read_config) | \
        st_configure_imsd.to(st_read_config) | \
        st_get_imsi.to(st_read_config) | \
        st_wait_events.to(st_read_config) | \
        st_wait_for_usim.to(st_read_config)

    e_usim_found = \
        st_wait_for_usim.to(st_get_imsi)

    e_configured = \
        st_configure_imsd.to(st_wait_events)

    e_st_failed = \
        st_read_config.to(st_failed) | \
        st_connect_modem.to(st_failed) | \
        st_configure_imsd.to(st_failed) | \
        st_get_imsi.to(st_failed) | \
        st_wait_events.to(st_failed) | \
        st_wait_for_usim.to(st_failed)

    def __init__(self, qmi_uri: str, use_proxy: bool = False, config_file: str = "pdc.toml") -> None:
        # FIXME: check if device has a signal for disconnects
        # possible to watch the cdc-wdm inode?
        self._device: Qmi.Device = None
        self._opened_services: list = []
        self._imsa: IMSApplication
        self._imss: IMSSettings
        self._imsp: IMSPresence
        self._uim: UIM
        self._plmn: PLMN
        self._open_flags = Qmi.DeviceOpenFlags.AUTO | Qmi.DeviceOpenFlags.EXPECT_INDICATIONS
        self.qmi_uri: str = qmi_uri
        self.qrtr: Optional(int) = None
        self._imsd_cfg = Config(config_file)

        # amount of time to wait at the start of imsi
        self._wait_on_imsi_s = None

        # keep track of active sessions (e.g. primary simcard assigned)
        self._uim_sessions = [False, False]

        if use_proxy:
            self._open_flags |= Qmi.DeviceOpenFlags.PROXY

        enable_qmi_logging()

        super().__init__(allow_event_without_transition=True)

    def on_exit_state(self, event, state):
        """ Called before every transition happen """
        LOG.info(f"Leaving state '{state}' by event '{event}'")

    def on_enter_state(self, event, state):
        LOG.info(f"Entering state '{state}' by event '{event}'")

    async def open_modem_file(self):
        file = Path(self.qmi_uri)
        if not file.exists():
            raise ModemMissing(f"File {self.qmi_uri} does not exist!")

        file = Gio.File.new_for_path(self.qmi_uri)
        self._device = await Qmi.Device.new(file)

    async def open_modem_qrtr(self, timeout: int = 3):
        qrtr = 0
        try:
            # a simple conversion as qrtr_get_node_for_uri doesn't work in python
            if len(self.qmi_uri) > 7:
                qrtr = int(self.qmi_uri[7:])
        except ValueError:
            raise InvalidUri(f"{self.qmi_uri} is an invalid uri!")
        self.qrtr = qrtr
        self._qrtr_bus = await Qrtr.Bus.new(int(timeout * 1000))
        self._qrtr_node = self._qrtr_bus.peek_node(self.qrtr)
        if not self._qrtr_node:
            raise IMSDError(f"Couldn't find the QRTR node {self.qrtr}")

        self._device = await Qmi.Device.new_from_node(self._qrtr_node)
        LOG.info(f"Successful connected to QRTR via {self.qmi_uri}")

    async def open_modem(self, timeout: int = 3):
        LOG.info(f"Try opening qmi modem {self.qmi_uri}!")
        if self.qmi_uri.startswith('/'):
            await self.open_modem_file()
        elif self.qmi_uri.startswith('qrtr://'):
            await self.open_modem_qrtr(timeout)
        else:
            raise InvalidUri(f"{self.qmi_uri} is invalid!")

    async def connect_services(self, timeout: int = 3):
        await self._device.open(self._open_flags, timeout)
        LOG.info(f"Opened QMI device {self.qmi_uri}")

        LOG.debug("Opening IMS application service")
        self._imsa = IMSApplication(self._device)
        await self._imsa.open()
        self._opened_services.append(self._imsa)
        await self._imsa.set_bind(0)

        LOG.debug("Opening IMS settings service")
        self._imss = IMSSettings(self._device)
        await self._imss.open()
        self._opened_services.append(self._imss)
        await self._imss.set_bind(0)

        LOG.debug("Opening NAS service")
        self._nas = NAS(self._device)
        await self._nas.open()
        self._opened_services.append(self._nas)

        LOG.debug("Opening PDC service")
        self._pdc = PDC(self._device)
        await self._pdc.open()
        self._opened_services.append(self._pdc)
        self._pdc.cb_config_change = self.cb_config_change
        await self._pdc.register()

        # Opening IMSPrsence service results in an internal error
        #LOG.debug("Opening IMS presence service")
        #self._imsp = IMSPresence(self._device)
        #await self._imsp.open()
        #self._opened_services.append(self._imsp)

        LOG.debug("Opening UIM service")
        self._uim = UIM(self._device)
        await self._uim.open()
        self._opened_services.append(self._uim)
        self._uim.cb_card_status = self.cb_card_status

    async def on_enter_st_read_config(self):
        try:
            self._imsd_cfg.parse_config()
        except InvalidConfig as e:
            LOG.error("Failed to parse config. {e}")
            await self.e_config_invalid()
        except:
            LOG.exception("Failed to parse config with unknown exception")
            await self.e_config_invalid()
        else:
            await self.e_config_valid()

    async def on_enter_st_connect_modem(self):
        try:
            await self.open_modem()
        except:
            LOG.exception("Failed to open modem")
            await self.e_modem_missing()
            return

        try:
            await self.connect_services()
        except:
            try:
                await self.close()
            except:
                pass

            LOG.error("Can not connect to all required services.")
            await self.e_modem_missing()
        else:
            await self.e_modem_connected()

    async def on_enter_st_wait_for_modem(self):
        """ We wait until the given modem appears """
        timeout_ms = 1000
        if self.qrtr is not None:
            LOG.info(f"Waiting for QRTR modem to appear qrtr://{self.qrtr}")
            while True:
                try:
                    self._qrtr_node = await self._qrtr_bus.wait_for_node(self.qrtr, timeout_ms)
                except:
                    await asyncio.sleep(timeout_ms / 1000)
                    continue

                if self._qrtr_node:
                    await self.e_modem_found()
                    return
        else:
            # regular qmi device
            LOG.info(f"Waiting for regular modem {self.qmi_uri} to be available")

            # wait first to prevent a state machine loop when the permission are wrong or other issue happen
            await asyncio.sleep(timeout_ms / 1000)

            while True:
                try:
                    file = Path(self.qmi_uri)
                    if file.exists():
                        await self.e_modem_found()
                        return
                except:
                    continue
                await asyncio.sleep(timeout_ms / 1000)

    async def ensure_simcard_present(self):
        """
        Ensures a UIM is available and assigned to the primary slot
        Raises a SimcardMissing if no simcard is available or assigned
        """
        try:
            primary, secondary, cards = await self._uim.get_uim_card_status()
            LOG.debug(f"UIM card status reported: {primary}, secondary: {secondary}, cards: {cards}")
            no_sims_available = True
            for _idx, card in cards.items():
                if card.state == Qmi.UimCardState.PRESENT:
                    no_sims_available = False

            if no_sims_available:
                self._uim_sessions[0] = False
                raise SimcardMissing("No simcard available!")

            if primary == NO_SESSION:
                # Currently only the primary profile is supported. Dual sim support might come later
                self._uim_sessions[0] = False
                LOG.info("There are simcards available, but not assigned to a slot (primary or secondary). Waiting for someone else changing this.")
                raise SimcardMissing("No session assigned!")
        except SimcardMissing:
            raise
        except:
            raise SimcardError("Unknown exception happened")

        self._uim_sessions[0] = True
        LOG.info(f"Found simcards: {primary}, {secondary}, {cards}")
        return primary, secondary, cards

    async def on_enter_st_get_imsi(self):
        # we use the get_imsi state as safe point to get back in case something change (PDC)
        if self._wait_on_imsi_s is not None:
            await asyncio.sleep(self._wait_on_imsi_s)

        try:
            await self.ensure_simcard_present()
            imsi = await self._uim.st_get_imsi()
            self._plmn = imsi_to_plmn(imsi)
            LOG.info(f"Read IMSI: (hidden) derived PLMN: {self._plmn}")
            await self.e_imsi_read()
        except SimcardMissing as exp:
            LOG.info(f"SimcardMissing raised {exp}")
            await self.e_usim_missing()
        except:
            LOG.exception("Failed to get IMSI")
            await self.e_usim_missing()

    async def on_enter_st_disable_imsd(self):
        """ Disable the ims services and wait a couple seconds before going into configuring and enable imsd """
        try:
            # disabling wifi for now and not enabling it
            to_disable = ['reg', 'volte', 'ut', 'wifi', 'data']
            enabled_services = await self._imss.get_ims_services()
            LOG.debug(f"IMS current enabled services: {enabled_services}")

            need_to_disable = False
            for svc in to_disable:
                if svc not in enabled_services:
                    continue

                if enabled_services[svc] is True:
                    need_to_disable = True
                    break

            if need_to_disable:
                LOG.debug("IMS need to disable some services")
                # disable imsd to reset its state
                disable_svcs = {svc: False for svc in to_disable}
                resp = await self._imss.set_ims_services(disable_svcs)
                enabled_services = await self._imss.get_ims_services()
                LOG.debug(f"IMS returned {enabled_services}")
            else:
                LOG.debug("IMS no need to disable some services.")

            # TODO: we could wait for an indication here instead
            LOG.debug("Waiting for 10 seconds to give the IMS stack time to follow up")
            await asyncio.sleep(10)
        except:
            LOG.exception("Failed to disable imsd")
            await self.st_failed()

        await self.e_disabled_imsd()

    async def on_enter_st_configure_imsd(self):
        try:
            # Set Call mode preference VoLTE
            # Disable Vowifi
            # Set IMS Enable
            #
            # ensure IMS is using IPv6 (0x40 -> ipv6?)
            # resp = await self._imss.set_apn_ip_type('ims', 0x40)

            to_enable = ['reg', 'volte', 'ut', 'wifi', 'data']
            LOG.info(f"IMS Require following IMS services: {to_enable}")

            enable_services = {svc: True for svc in to_enable}
            resp = await self._imss.set_ims_services(enable_services)

            enabled_services = await self._imss.get_ims_services()
            LOG.info(f"IMS service are now: {enabled_services}")

            resp = await self._nas.get_voice_preference()
            resp = await self._nas.set_voice_preference(Qmi.NasVoiceDomainPreference.PS_PREFERRED)
            resp = await self._nas.get_voice_preference()

            await self.e_configured()
        except:
            LOG.exception("Failed to Get Profiles")
            await self.e_st_failed()

    async def on_enter_st_wait_events(self):
        LOG.info("All configured. Waiting for state changes of the baseband.")
        LOG.info("Have a nice call")

    async def on_enter_st_failed(self):
        LOG.error("IMSD entered failed state! Shutting daemon down.")
        await shutdown()

    @staticmethod
    def contains_ready_cards(cards: dict) -> bool:
        for _idx, card in cards.items():
            if card.ready:
                return True
        return False

    async def cb_card_status(self, _old_state: CardsStatus, new_state: CardsStatus):
        await self.check_for_card_changes(new_state)

    async def cb_config_change(self, new_profile: bytes):
        # will be called twice for every PDC change:
        # 1st: with a new profile when start loading (with profile id)
        # 2nd: when the new profile has been loaded (empty)
        LOG.info(f"cb_config_change: new PDC profile {new_profile}")
        if not new_profile:
            # only trigger when new_profile is empty
            self._wait_on_imsi_s = 1.0
            await self.e_pdc_config_change()

    async def check_for_card_changes(self, new_state: CardsStatus):
        LOG.debug(f"Card status indication called with new {new_state}")
        prim, _secon, new_cards = new_state

        new_contains_cards = self.contains_ready_cards(new_cards)
        LOG.info(f"New cards available? {new_contains_cards}")
        if prim == NO_SESSION:
            # no session selected
            if self._uim_sessions[0]:
                self._uim_sessions[0] = False
                LOG.info("USIM disappeared.")
                if not self.st_wait_for_usim.is_active:
                    await self.e_usim_missing()
            return
        else:
            slot, app = index_to_slot_app(prim)
            if slot not in new_cards:
                LOG.debug("Couldn't find the assigned slot in the simcard status")
                return
            if not new_cards[slot].ready:
                LOG.debug("Assigned simcard slot doesn't contain a ready simcard")
                return

            if self._uim_sessions[0]:
                # Already active
                return

            self._uim_sessions[0] = True
            LOG.info("USIM found for primary profile")
            if self.st_wait_for_usim:
                await self.e_usim_found()
            return

    async def on_enter_st_wait_for_usim(self):
        LOG.info("Wait for a USIM to appear")
        self._task_periodic = LOOP.create_task(self.st_wait_for_usim_periodic())

    async def st_wait_for_usim_periodic(self):
        """ periodic checks if a usim is present in case
            the indication doesn't work as expected
        """
        poll_every_sec = 30
        while True:
            LOG.info("Periodic checking for USIM to be present")
            try:
                card_status = await self._uim.get_uim_card_status()
                await self.check_for_card_changes(card_status)
            except CancelledError:
                return
            except:
                LOG.exception("Failed to read simcard status")

            await asyncio.sleep(poll_every_sec)

    async def on_exit_st_wait_for_usim(self):
        if self._task_periodic:
            self._task_periodic.cancel()
        self._task_periodic = None

    async def start_fsm(self):
        await self.e_start()

    async def close(self, timeout = 3):
        for srv in self._opened_services:
            LOG.info(f"Closing service {srv}")
            await srv.close()

        if self._device and self._device.is_open():
            await self._device.close_async(timeout)

async def shutdown():
    """ In case of a severe failure, shutdown and exist """
    global IMSD
    LOG.warning("Shutting down openimsd-qcom")
    try:
        if IMSD:
            await IMSD.close()
    except Exception:
        LOG.exception("While shutting down")
    finally:
        if IMSD:
            IMSD = None
        LOG.error("Terminating loop")
        LOOP.stop()

def signal_handler(_data):
    """ handler unix signal and terminate the openimsd """
    global IMSD
    LOG.error("Signal received, closing QMI")
    if IMSD:
        LOG.info("Waiting for the close task to complete")
        asyncio.ensure_future(IMSD.close())
    IMSD = None
    LOG.error("Terminating")
    LOOP.stop()

def main():
    parser = argparse.ArgumentParser(
            prog='openimsd-qcom',
            description='Manage IMS subscription for QCOM basebands.')

    parser.add_argument('-d', '--device',
                        required=True,
                        help="The QMI device uri. On smartphones use 'qrtr://0'. On Laptop use '/dev/cdc-wdm0'")
    parser.add_argument('-v', '--verbose',
                        action='count', default=0,
                        help="Increase loglevel")
    parser.add_argument('-q', '--quiet',
                        action='count', default=0,
                        help="Only print errors and warnings")
    parser.add_argument('-c', '--config',
                        default='imsd.toml',
                        help="Path to the config file")
    parser.add_argument('-l', '--logfile',
                        help="Path to log file")
    args = parser.parse_args()
    if args.quiet and args.verbose:
        print("Can't set quiet and verbose at the same time!")
        sys.exit(1)

    loglevel = logging.INFO
    if args.verbose == 1:
        loglevel = logging.DEBUG
    elif args.quiet == 1:
        loglevel = logging.WARNING
    elif args.quiet == 2:
        loglevel = logging.ERROR
    elif args.quiet > 2:
        loglevel = logging.CRITICAL

    logformat = '%(asctime)s %(levelname)s %(message)s'
    logging.basicConfig(format=logformat, level=loglevel)
    if args.logfile:
        logfile = logging.FileHandler(args.logfile)
        logfile.setLevel(loglevel)
        formatter = logging.Formatter('%(asctime)s %(name)s %(levelname)s %(message)s')
        logfile.setFormatter(formatter)
        logging.getLogger().addHandler(logfile)

    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGHUP, signal_handler, None)
    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGTERM, signal_handler, None)

    device = args.device
    config_file = args.config
    cfg_path = Path(config_file)
    if not cfg_path.exists():
        LOG.error(f"Give config file {config_file} doesn't exist.")
        sys.exit(2)

    IMSD = OpenIMSD(device, config_file = config_file)

    # from statemachine.contrib.diagram import DotGraphMachine
    # graph = DotGraphMachine(OpenIMSD)
    # dot = graph()
    # dot.write_png('/tmp/foo.png')
    # import sys
    # sys.exit(1)
    task = LOOP.create_task(IMSD.start_fsm())
    try:
        LOOP.run_forever()
    except KeyboardInterrupt:
        pass

    if IMSD:
        LOG.info("Main: Trying to close QMI device")
        close_task = LOOP.create_task(IMSD.close())
        LOOP.run_until_complete(close_task)

if __name__ == "__main__":
    main()
