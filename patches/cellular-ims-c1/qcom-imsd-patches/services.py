#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import asyncio
import logging
from typing import NewType
import gi

gi.require_version('Qmi', '1.0')
gi.require_version('Qrtr', '1.0')

from gi.repository import Qmi, Qrtr

from .data import *
from .common import *
from .utils import *

LOG = logging.getLogger()



NO_SESSION = 65535
def index_to_slot_app(index: int) -> tuple[int, int]:
    """
    Converts a UIM session index into slot / app
    E.g. Primary GW Index into the assigned slot and application
    """
    slot = (index >> 8) & 0xff
    app = index & 0xff
    return slot, app


CardsStatus = NewType('CardsStatus', tuple[int, int, dict[int, SimState]])

# UIM files (16 bit, host byte order)
USIM_FILE_IMSI = 0x6f07

# UIM paths (16 bit values as little endian)
USIM_PATH_UIM = [0x00, 0x3f, 0xff, 0x7f]

class UIM():
    """ a class abstracting the QMI UIM (User Identification Module) service """
    def __init__(self, device: Qmi.Device, log_private: bool = False):
        self._device = device
        self._uim: Qmi.ClientUim = None
        self.last_card_status: CardsStatus = (NO_SESSION, NO_SESSION, {})
        self.last_slot_status = {}
        self._card_status_ind = None
        self._slot_status_ind = None
        self._log_private = log_private
        self._callbacks = set()

        # Contains {'1': PhysicalSlotStatusSlot, ...}
        self._physical_status = {}

        # async callbacks
        self.cb_card_status = None
        self.cb_slot_status = None

    async def open(self, timeout: int = 3):
        """ Connect to the UIM service """
        LOG.debug("Try to connect to UIM service.")
        self._uim = await self._device.allocate_client(Qmi.Service.UIM, Qmi.CID_NONE, timeout)
        self._card_status_ind = self._uim.connect("card-status", self._on_uim_card_status)
        self._slot_status_ind = self._uim.connect("slot-status", self._on_uim_slot_status)
        LOG.debug("Try to register for Events")
        await self.register_events(timeout)

    async def register_events(self, timeout: int = 3):
        reg_events = Qmi.MessageUimRegisterEventsInput.new()
        reg_events.set_event_registration_mask(Qmi.UimEventRegistrationFlag.CARD_STATUS | Qmi.UimEventRegistrationFlag.PHYSICAL_SLOT_STATUS)

        resp = await self._uim.register_events(reg_events, timeout)
        LOG.info(f"Register Events: resp {resp}")

    # FIXME: add type of req as well list[gi.repository.Qmi.MessageUimGetCardStatusOutputCardStatusCardsElementGir]
    def parse_uim_card_status(self, card_status: list[Qmi.IndicationUimCardStatusOutputCardStatusCardsElementGir]) -> \
                CardsStatus:
        idx = -1
        cards = {}

        prim_gw, prim_1x, secon_gw, secon_1x, states = card_status
        for state in states:
            idx += 1

            card = {}
            card['state'] = state.card_state
            card['error'] = state.error_code

            LOG.debug(f"UIM Card {idx} State {enum_nick(state.card_state)}")
            LOG.debug(f"UIM Card {idx} Error {enum_nick(state.error_code)}")

            if state.card_state != Qmi.UimCardState.PRESENT:
                cards[idx] = SimState(slot=idx, ready=False, state=state.card_state)
                continue

            has_isim = False
            ready = False
            usim_aid = []
            for app in state.applications:
                LOG.debug(f"UIM Card {idx} App state: {enum_nick(app.state)}")
                LOG.debug(f"UIM Card {idx} App type:  {enum_nick(app.type)}")
                aid = bytes(app.application_identifier_value)
                LOG.debug(f"UIM Card {idx} App aid:   {aid.hex()}")

                # Require an USIM
                if app.type == Qmi.UimCardApplicationType.USIM:
                    ready = (app.state == Qmi.UimCardApplicationState.READY)
                    usim_aid = aid
                elif app.type == Qmi.UimCardApplicationType.ISIM:
                    has_isim = True
                else:
                    # unsupported type (RSIM/SIM/..)
                    continue

            cards[idx] = SimState(slot=idx, ready=ready, state=state.card_state, aid=usim_aid, has_isim=has_isim)
        return prim_gw, secon_gw, cards

    def _on_uim_card_status(self, uim_client, uim_card_status_ind):
        """ Card Status will change e.g. when pin entered or a new card inserted/removed """
        uim_card_status = get_tlv_value(uim_card_status_ind.get_card_status, [])
        old_card_status = self.last_card_status
        card_status = self.last_card_status = self.parse_uim_card_status(uim_card_status)
        LOG.info(f"Received UIM Card Status Indication: {card_status}")

        if self.cb_card_status:
            task = asyncio.get_running_loop().create_task(self.cb_card_status(old_card_status, card_status))
            self._callbacks.add(task)
            task.add_done_callback(self._callbacks.discard)

    async def get_uim_card_status(self, timeout: int = 3) -> tuple[int, int, dict[int, SimState]]:
        """ Request UIM Card Status to determine if the SIM card is already unlocked """
        resp = await self._uim.get_card_status(None, timeout)
        card_status = self.last_card_status = self.parse_uim_card_status(resp.get_card_status())
        return card_status

    def parse_slot_status(self, uim_slot_status: Qmi.IndicationUimSlotStatusOutput | Qmi.MessageUimGetSlotStatusOutput) -> dict[str, Qmi.PhysicalSlotStatusSlot]:
        slot_status = get_tlv_value(uim_slot_status.get_physical_slot_status, [])
        new_slot_status = {}
        for status in slot_status:
            new_slot_status[status.logical_slot] = status

        self.last_slot_status = new_slot_status
        return new_slot_status

    def _on_uim_slot_status(self, uim_client: Qmi.ClientUim, uim_slot_status: Qmi.IndicationUimSlotStatusOutput):
        """ Slot Status will change when a sim card will insert or remove. Might require special handling for eUICC (eSIM) """
        LOG.debug("Received Uim Slot Indication")
        old_slot_status = self.last_slot_status
        new_slot_status = self.parse_slot_status(uim_slot_status)
        LOG.debug(f"Uim Slot Indication: parsed {new_slot_status}")

        if self.cb_slot_status:
            asyncio.get_running_loop().create_task(self.cb_slot_status(old_slot_status, new_slot_status))

    async def get_uim_slot_status(self, timeout: int = 3) -> dict[str, Qmi.PhysicalSlotStatusSlot]:
        """
        Request UIM Slot Status to determine if the SIM card is present
        """
        resp = await self._uim.get_slot_status(None, timeout)
        slot_status = self.last_slot_status = self.parse_slot_status(resp)

        return slot_status

    def check_transparent_read(self, resp: Qmi.MessageUimReadTransparentOutput):
        result = get_tlv_value(resp.get_result, None)
        card_result = get_tlv_value(resp.get_card_result, None)
        if card_result is None:
            raise SimcardError("Failed to get a card result. Simcard present?")
        if card_result.value_card_result_sw1 != 0x90 or card_result.value_card_result_sw2 != 0:
            raise SimcardError("SimcardError: Simcard Response not 0x9000")

    async def st_get_imsi(self, session: Qmi.UimSessionType = Qmi.UimSessionType.PRIMARY_GW_PROVISIONING, timeout: int = 3) -> str:
        LOG.info(f"Reading IMSI on session {enum_nick(session)}")
        read_transparent = Qmi.MessageUimReadTransparentInput.new()
        read_transparent.set_file(USIM_FILE_IMSI, USIM_PATH_UIM)
        read_transparent.set_read_information(0, 2048)
        # AID = 0x0 seems to work fine.
        read_transparent.set_session(session, [0x0])

        resp = await self._uim.read_transparent(read_transparent, timeout)
        self.check_transparent_read(resp)
        content = resp.get_read_result()
        decoded = dec_imsi(content.hex())
        if not decoded:
            raise InvalidImsi("Read from USIM")

        if self._log_private:
            LOG.info(f"Read IMSI '{decoded}'")

        return decoded

    async def close(self, timeout = 3):
        if not self._device:
            return

        if self._card_status_ind:
            self._uim.disconnect(self._card_status_ind)
            self._card_status_ind = None

        if self._uim:
            LOG.info("Trying to close UIM session")
            await self._device.release_client(self._uim, Qmi.DeviceReleaseClientFlags.RELEASE_CID, timeout=3)

class NAS():
    """ a class abstracting the QMI NAS service """
    def __init__(self, device: Qmi.Device, log_private: bool = False):
        self._device = device
        self._log_private = log_private
        self._nas = None

    async def open(self, timeout: int = 3):
        """ Connect to the QMI service """
        LOG.info(f"Try to connect to NAS service.")
        self._nas = await self._device.allocate_client(Qmi.Service.NAS, Qmi.CID_NONE, timeout)

    async def get_voice_preference(self, timeout: int = 3):
        svcs = {}
        resp = await self._nas.get_system_selection_preference(None, timeout)
        voice_preference = get_tlv_value(resp.get_voice_domain_preference, None)
        return voice_preference

    async def set_voice_preference(self, preference: Qmi.NasVoiceDomainPreference,  timeout: int = 3):
        set_system_pref = Qmi.MessageNasSetSystemSelectionPreferenceInput.new()
        set_system_pref.set_voice_domain_preference(preference)
        resp = await self._nas.set_system_selection_preference(set_system_pref, timeout)
        result = get_tlv_value(resp.get_result, None)
        return result

    async def close(self, timeout: int = 3):
        if not self._device:
            return

        if self._nas:
            LOG.info("Trying to close NAS session")
            await self._device.release_client(self._nas, Qmi.DeviceReleaseClientFlags.RELEASE_CID, timeout)


class PDC:
    """ a class abstracting the QMI PDC (Persistent Device Configuration) service """
    def __init__(self, device: Qmi.Device, log_private: bool = False):
        self._device = device
        self._log_private = log_private
        self._callbacks = set()

        # List-Configs
        self._list_flag = asyncio.Event()
        self._list_ind = None
        self._config_ids = []

        # Get Config Info
        self._config_flag = asyncio.Event()
        self._config_ind = None
        ## a tuple (bool, optional())
        self._config_info = (False, False)

        # Get Selected Config
        self._selected_flag = asyncio.Event()
        self._selected_ind = None
        self._selected_config = (False, False)

        # Set Selected Flag
        self._set_selected_flag = asyncio.Event()
        self._set_selected_ind = None
        self._set_selected_info = (False, False)

        # Activate Config
        self._activate_flag = asyncio.Event()
        self._activate_ind = None
        self._activate_info = (False, False)

        # Config Change
        self._config_change_ind = None
        self.cb_config_change = None

    async def open(self, timeout: int = 3):
        """ Connect to the PDC service """
        LOG.info(f"Try to connect to PDC service.")
        self._pdc = await self._device.allocate_client(Qmi.Service.PDC, Qmi.CID_NONE, timeout)
        self._list_ind = self._pdc.connect("list-configs", self.on_pdc_list_ind)
        self._config_ind = self._pdc.connect("get-config-info", self.on_pdc_get_config_info_ind)
        self._selected_ind = self._pdc.connect("get-selected-config", self.on_pdc_get_selected_ind)
        self._set_selected_ind = self._pdc.connect("set-selected-config", self._on_pdc_set_selected_ind)
        self._activate_ind = self._pdc.connect("activate-config", self._on_pdc_activate_config)
        self._config_change_ind = self._pdc.connect("config-change", self._on_pdc_config_change)

    async def activate_config(self, config_type: Qmi.PdcConfigurationType = Qmi.PdcConfigurationType.SOFTWARE, timeout: int = 3):
        activate_config = Qmi.MessagePdcActivateConfigInput.new()
        activate_config.set_config_type(config_type)
        self._activate_flag.clear()
        try:
            _resp = await self._pdc.activate_config(activate_config, timeout=timeout)
            await asyncio.wait_for(self._activate_flag.wait(), timeout=timeout)
            return self._activate_info
        except TimeoutError:
            raise QmiTimeout("PDC list configs timed out")
        except PdcError:
            raise
        except Exception as exp:
            LOG.exception(f"Exp {exp}")
            raise QmiError(f"Failed with exception {exp}")

    def _on_pdc_config_change(self, _pdc_client, pdc_change_config_ind: Qmi.IndicationPdcConfigChangeOutput):
        """ The current configuration changed """
        new_pdc_id = get_tlv_value(pdc_change_config_ind.get_type_with_id_v2, None)
        if new_pdc_id is not None:
            new_pdc_id = new_pdc_id[1]
        LOG.info(f"Received PDC Config Change Indication: New Config {new_pdc_id}")

        if self.cb_config_change:
            task = asyncio.get_running_loop().create_task(self.cb_config_change(new_pdc_id))
            self._callbacks.add(task)
            task.add_done_callback(self._callbacks.discard)
            #LOOP.call_soon(task)

    def _on_pdc_activate_config(self, _pdc_client, pdc_activate_config):
        result = get_tlv_value(pdc_activate_config.get_indication_result, None)
        self._activate_info = (True, result)
        self._activate_flag.set()

    async def set_selected_config(self, profile: ConfigId, timeout: int = 3):
        set_config = Qmi.MessagePdcSetSelectedConfigInput.new()
        set_config.set_type_with_id_v2(Qmi.PdcConfigurationType.SOFTWARE, profile.as_list())
        self._set_selected_flag.clear()
        try:
            _resp = await self._pdc.set_selected_config(set_config, timeout=timeout)
            await asyncio.wait_for(self._set_selected_flag.wait(), timeout=timeout)

        except TimeoutError:
            raise QmiTimeout("PDC list configs timed out")
        except PdcError:
            raise
        except Exception as exp:
            LOG.exception(f"Exp {exp}")
            raise QmiError(f"Failed with exception {exp}")

        return self._set_selected_info

    def _on_pdc_set_selected_ind(self, _pdc_client, pdc_set_selected):
        result = get_tlv_value(pdc_set_selected.get_indication_result, None)
        self._set_selected_info = (True, result)
        self._set_selected_flag.set()

    async def get_selected_config(self, timeout: int = 3):
        try:
            self._selected_flag.clear()
            selected = Qmi.MessagePdcGetSelectedConfigInput.new()
            selected.set_config_type(Qmi.PdcConfigurationType.SOFTWARE)
            resp = await self._pdc.get_selected_config(selected, timeout=timeout)
            # TODO: check result
            await asyncio.wait_for(self._selected_flag.wait(), timeout=timeout)
            return self._selected_config

        except TimeoutError:
            raise QmiTimeout("PDC list configs timed out")
        except PdcError:
            raise
        except Exception as exp:
            LOG.exception(f"Exp {exp}")
            raise QmiError(f"Failed with exception {exp}")

    async def get_list(self, timeout: int = 3):
        # TODO: add locks again concurrent get_list()
        # TODO: rename get_list() into get_list_full
        try:
            # the request is empty, the indication contains all PDCs
            configs = Qmi.MessagePdcListConfigsInput.new()
            configs.set_config_type(Qmi.PdcConfigurationType.SOFTWARE)
            self._list_flag.clear()
            _resp = await self._pdc.list_configs(configs, timeout)
            LOG.debug("Requested a list config. Waiting for the indication arrive.")
            await asyncio.wait_for(self._list_flag.wait(), timeout=timeout)
            # self._config_ids are set, resolve the ids

            config_list = {}
            for config_id in self._config_ids:
                try:
                    get_config_input = Qmi.MessagePdcGetConfigInfoInput.new()
                    get_config_input.set_type_with_id_v2(Qmi.PdcConfigurationType.SOFTWARE, config_id.as_list())
                    self._config_flag.clear()
                    _resp = await self._pdc.get_config_info(get_config_input, timeout=timeout)
                    await asyncio.wait_for(self._config_flag.wait(), timeout=timeout)
                    match self._config_info:
                        case (True, config_info):
                            config_list[config_id] = config_info
                except TimeoutError:
                    raise QmiTimeout(f"PDC get config info() timed out for {config_id}")
                except:
                    raise QmiError("Failed to get Config Error")

            self._config_list = config_list

        except TimeoutError:
            raise QmiTimeout("PDC list configs timed out")
        except PdcError:
            raise
        except Exception as exp:
            LOG.exception(f"Exp {exp}")
            raise QmiError(f"Failed with exception {exp}")

        return config_list

    # TODO: use weakref as suggested by stackoverflow
    # https://stackoverflow.com/questions/1364923/how-to-connect-to-a-gobject-signal-in-python-without-it-keeping-a-reference-to#1364959
    def on_pdc_list_ind(self, pdc_client, pdc_list_configs):
        # indication_pdc_list_configs_indication_parse -> gi.repository.Qmi.IndicationPdcListConfigsOutput
        LOG.debug(f"Received PDC list indications: pdc: {pdc_client}, configs: {pdc_list_configs}")
        config_ids = []
        qmi_configs = pdc_list_configs.get_configs()
        for config in qmi_configs:
            if config.config_type == Qmi.PdcConfigurationType.SOFTWARE:
                cfg_id = ConfigId(config.id)
                config_ids.append(cfg_id)
                LOG.debug(f"Config: id {cfg_id}")

        self._config_ids = config_ids
        self._list_flag.set()

    def on_pdc_get_config_info_ind(self, pdc_client, pdc_config_info):
        LOG.debug(f"Received PDC Get Config Info Indication: pdc: {pdc_client}, configs: {pdc_config_info}")
        config_info = {}
        # TODO: match pdc_config_info.get_indication_result():
        match pdc_config_info.get_description():
            case desc if type(desc) is str:
                config_info["description"] = desc
        match pdc_config_info.get_total_size():
            case total_size if type(total_size) is int:
                config_info["total_size"] = total_size
        match pdc_config_info.get_version():
            case version if type(version) is int:
                config_info["version"] = version

        try:
            config_info = ConfigInfo(**config_info)
            self._config_info = (True, config_info)
        except Exception as exp:
            self._config_info = (False, exp)
        finally:
            self._config_flag.set()

    def on_pdc_get_selected_ind(self, pdc_client, pdc_selected_info):
        LOG.debug(f"Received PDC Get Selected Info Indication: pdc: {pdc_client}, configs: {pdc_selected_info}")
        pending = get_tlv_value(pdc_selected_info.get_pending_id)
        active = get_tlv_value(pdc_selected_info.get_active_id)
        if active:
            active = ConfigId(active)
        if pending:
            pending = ConfigId(pending)

        LOG.debug(f"PDC Selected Info Active {active}")
        LOG.debug(f"PDC Selected Info Pending {pending}")

        self._selected_config = (True, (active, pending))
        self._selected_flag.set()

    async def register(self, timeout: int = 3):
        """ Register for indications """
        register: Qmi.MessagePdcRegisterInput = Qmi.MessagePdcRegisterInput.new()
        register.set_enable_reporting(True) # get Config Change Ind
        try:
            resp = await self._pdc.register(register, timeout=timeout)
            return resp
        except TimeoutError:
            raise QmiTimeout("PDC register timed out")
        except PdcError:
            raise
        except Exception as exp:
            LOG.exception(f"Exp {exp}")
            raise QmiError(f"Failed with exception {exp}")

    async def close(self, timeout: int = 3):
        if not self._device:
            return

        if self._pdc:
            LOG.info("Trying to close PDC session")
            await self._device.release_client(self._pdc, Qmi.DeviceReleaseClientFlags.RELEASE_CID, timeout)

        LOG.info("Trying to close QMI device")

        # TODO: free other indications
        if self._list_ind:
            self._pdc.disconnect(self._list_ind)
            self._list_ind = None

        LOG.info("Closed QMI device")

class IMSPresence:
    """ a class abstracting the QMI IMSP (IMS Presence) service """
    def __init__(self, device: Qmi.Device, log_private: bool = False):
        self._device = device
        self._log_private = log_private
        self._imsp = None

    async def open(self, timeout: int = 3):
        """ Connect to the QMI service """
        LOG.info(f"Try to connect to IMSP service.")
        self._imsp = await self._device.allocate_client(Qmi.Service.IMSP, Qmi.CID_NONE, timeout)

    async def close(self, timeout: int = 3):
        if not self._device:
            return

        if self._imsp:
            LOG.info("Trying to close IMSP session")
            await self._device.release_client(self._imsp, Qmi.DeviceReleaseClientFlags.RELEASE_CID, timeout)

class IMSApplication:
    """ a class abstracting the QMI IMSA (IMS Application) service """
    def __init__(self, device: Qmi.Device, log_private: bool = False):
        self._device = device
        self._log_private = log_private
        self._imsa: Qmi.ClientImsa

    async def open(self, timeout: int = 3):
        """ Connect to the QMI service """
        LOG.info(f"Try to connect to IMSA service.")
        self._imsa = await self._device.allocate_client(Qmi.Service.IMSA, Qmi.CID_NONE, timeout)

    async def close(self, timeout: int = 3):
        if not self._device:
            return

        if self._imsa:
            LOG.info("Trying to close IMSA session")
            await self._device.release_client(self._imsa, Qmi.DeviceReleaseClientFlags.RELEASE_CID, timeout)

    async def get_services_status(self, timeout: int = 3):
        resp = await self._imsa.get_ims_services_status(None, timeout)

        return resp

    async def get_reg_status(self, timeout: int = 3):
        resp = await self._imsa.get_ims_registration_status(None, timeout)
        return resp

    async def get_bind(self, timeout: int = 3):
        bind_resp = await self._imsa.get_bind(Qmi.MessageImsaGetBindInput(), timeout)
        bind = get_tlv_value(bind_resp.get_binding, None)
        return bind

    async def set_bind(self, bind_id: int, timeout: int = 3):
        if bind_id < 0 or bind_id > 3:
            raise ValueError(f"Bind id must between 0 and 3! {bind_id}")
        set_bind = Qmi.MessageImsaBindInput()
        set_bind.set_binding(bind_id)
        resp = await self._imsa.bind(set_bind, timeout)

def convert_ims_pol_rat_to_input(rat: Qmi.MessageImsGetImsPolicyManagerSettingsOutputRatApnElement) -> Qmi.MessageImsSetImsPolicyManagerSettingsInputRatApnElement:
    """
    Convert a MessageImsGetImsPolicyManagerSettingsOutputRatApnElement into MessageImsSetImsPolicyManagerSettingsInputRatApnElement
    """
    # TODO: use glib StructInfo to do this or find a better way
    keys = 'rat', 'apn_type', 'service_mask', 'auth_type', 'ip_type'
    out = Qmi.MessageImsSetImsPolicyManagerSettingsInputRatApnElement()
    for key in keys:
       setattr(out, key, getattr(rat, key))
    return out

class IMSSettings():
    """ a class abstracting the QMI IMSS (IMS Settings) service """
    def __init__(self, device: Qmi.Device, log_private: bool = False):
        self._device = device
        self._log_private = log_private
        self._imss = None

    async def open(self, timeout: int = 3):
        """ Connect to the QMI service """
        try:
            LOG.info(f"Try to connect to IMSS service.")
            self._imss = await self._device.allocate_client(Qmi.Service.IMS, Qmi.CID_NONE, timeout)

        except Exception as exp:
            LOG.exception(f"Exception while opening occurred {exp}")
            await shutdown()

    async def set_apn_ip_type(self, apn: str, ip_type: int, timeout: int = 3):
        """ Set the ip type for a specific apn type

        FIXME! this doesn't work and returns an internal failure.
        Maybe we need to pass all configuration?
        """
        current = await self._imss.get_ims_policy_manager_settings(gi.repository.Qmi.MessageImsGetImsPolicyManagerSettingsInput.new(), timeout)
        # we require to have APNs and RAT APN filled
        rats = get_tlv_value(current.get_rat_apn, None)
        apns = get_tlv_value(current.get_apns, None)

        if rats is None or apns is None:
            return None

        apn_pos = -1
        for i in range(len(apns)):
            if apns[i] == apn:
                apn_pos = i
                break

        if apn_pos == -1:
            return None

        # convert MessageImsGetImsPolicyManagerSettingsOutputRatApnElement -> Input
        new_rats = [convert_ims_pol_rat_to_input(rat) for rat in rats]
        # FIXME: let not edit it and check what happens
        #new_rats[i].ip_type = ip_type

        settings = Qmi.MessageImsSetImsPolicyManagerSettingsInput()
        settings.set_rat_apn(new_rats)

        resp = await self._imss.set_ims_policy_manager_settings(settings, timeout)
        return resp

    async def get_ims_services(self, timeout: int = 3):
        svcs = {}
        ims = await self._imss.get_ims_services_enabled_setting(None, timeout)
        availables = {
            'reg': 'get_ims_registration_service_enable',
            'sms': 'get_ims_sms_service_enable',
            'ussd': 'get_ims_ussd_service_enable',
            'ut': 'get_ims_ut_service_enable',
            'vt': 'get_ims_video_telephony_service_enable',
            'volte': 'get_ims_voice_service_enable',
            'wifi': 'get_ims_voice_wifi_service_enable',
            'data': 'get_ims_mobile_data_enable',
        }

        for key, fname in availables.items():
            func = getattr(ims, fname, None)
            if func is None:
                svcs[key] = None
                continue

            svcs[key] = get_tlv_value(func, None)

        return svcs

    async def set_ims_services(self, svcs: dict, timeout: int = 3):
        """
        enable or disable IMS services
        @param svcs: a dict of services and their expected state
        """
        available_svcs = {
            'reg': 'set_ims_registration_service_enable',
            'sms': 'set_ims_sms_service_enable',
            'ussd': 'set_ims_ussd_service_enable',
            'ut': 'set_ims_ut_service_enable',
            'vt': 'set_ims_video_telephony_service_enable',
            'volte': 'set_ims_voice_service_enable',
            'wifi': 'set_ims_voice_wifi_service_enable',
            'data': 'set_ims_mobile_data_enable',
        }

        #      Qmi.MessageImsSetImsServicesEnabledSettingInput
        set_svcs = Qmi.MessageImsSetImsServicesEnabledSettingInput.new()
        for svc, state in svcs.items():
            if svc in available_svcs:
                fun = getattr(set_svcs, available_svcs[svc])
                fun(state)

        # service mask will use 'volte' service
        if 'volte' in svcs:
            set_svcs.set_ims_service_mask_by_operator_enable(0x3 if svcs['volte'] else 0)

        # Set it to preferred mobile
        set_svcs.set_ims_call_mode_preference(1)

        resp = await self._imss.set_ims_services_enabled_setting(set_svcs, timeout)

        result = get_tlv_value(resp.get_result, None)
        return (resp, result)

    #async def get_bind(self, timeout: int = 3):
        #bind = await self._imss.get_bind(Qmi.MessageImsGetBindInput(), timeout)
        #LOG.info(f"IMSA: bind {bind}")
        #return bind

    async def set_bind(self, bind_id: int, timeout: int = 3):
        if bind_id < 0 or bind_id > 3:
            raise ValueError(f"Bind id must between 0 and 3! {bind_id}")
        set_bind = Qmi.MessageImsBindInput()
        set_bind.set_binding(bind_id)
        resp = await self._imss.bind(set_bind, timeout)

    async def close(self, timeout: int = 3):
        if not self._device:
            return

        if self._imss:
            LOG.info("Trying to close IMSS session")
            await self._device.release_client(self._imss, Qmi.DeviceReleaseClientFlags.RELEASE_CID, timeout)

