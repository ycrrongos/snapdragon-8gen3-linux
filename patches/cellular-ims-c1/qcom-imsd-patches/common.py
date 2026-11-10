
from gi.repository import GLib

def get_tlv_value(func, default = None):
    try:
        return func()
    except GLib.GError as exp:
        if not exp.domain.startswith("qmi_"):
            raise

        return default

class IMSDError(RuntimeError):
    pass

class ModemMissing(IMSDError):
    pass

class PdcError(IMSDError):
    pass

class SimcardError(IMSDError):
    pass

class SimcardMissing(IMSDError):
    """ No Simcard available """
    pass

class InvalidImsi(IMSDError, ValueError):
    pass

class InvalidConfig(IMSDError):
    pass

class InvalidUri(IMSDError):
    pass

class QmiTimeout(IMSDError):
    pass

class QmiError(IMSDError):
    pass

def enum_nick(v):
    for attr in ("value_nick", "name", "value_name"):
        if hasattr(v, attr):
            return getattr(v, attr)
    return str(v)
