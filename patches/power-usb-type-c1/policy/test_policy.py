import importlib.util
from pathlib import Path
import unittest
s=importlib.util.spec_from_file_location('policy',Path(__file__).with_name('cerro-usb-current.py')); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
class PolicyTests(unittest.TestCase):
 def values(self,**kw):
  d=dict(POWER_SUPPLY_ONLINE='1',POWER_SUPPLY_USB_TYPE='Unknown [SDP] PD',POWER_SUPPLY_VOLTAGE_NOW='4900000',POWER_SUPPLY_CURRENT_MAX='900000',POWER_SUPPLY_INPUT_CURRENT_LIMIT='500000');d.update(kw);return d
 def test_verified_class(self):self.assertEqual(m.target_current(self.values(),350),900000)
 def test_idempotent(self):self.assertIsNone(m.target_current(self.values(POWER_SUPPLY_INPUT_CURRENT_LIMIT='900000'),350))
 def test_pd(self):self.assertIsNone(m.target_current(self.values(POWER_SUPPLY_USB_TYPE='SDP [PD]'),350))
 def test_unknown_source(self):self.assertIsNone(m.target_current(self.values(POWER_SUPPLY_CURRENT_MAX='500000'),350))
 def test_offline(self):self.assertIsNone(m.target_current(self.values(POWER_SUPPLY_ONLINE='0'),350))
 def test_hot(self):self.assertIsNone(m.target_current(self.values(),400))
 def test_bad_voltage(self):self.assertIsNone(m.target_current(self.values(POWER_SUPPLY_VOLTAGE_NOW='4300000'),350))
 def test_missing(self):self.assertIsNone(m.target_current({},350))
if __name__=='__main__': unittest.main()
