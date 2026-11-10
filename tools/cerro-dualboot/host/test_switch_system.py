"""Transaction/fault checks: no physical device is accessed by this suite."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('switch_system',Path(__file__).with_name('switch-system.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class FakePhone:
 def __init__(self):
  self.mode='android';self.serial='test';self.calls=[];self.fail_target=None
  self.values={'boot_b':'a'*64,'dtbo_b':'b'*64,'boot_a':'c'*64,'dtbo_a':'d'*64}
  self.slot='b';self.root_uuid='same-root'
 def part(self,k,s):return k+'_'+s
 def info(self):
  return dict(mode=self.mode,slot=self.slot,root_uuid=self.root_uuid,boot_id='before',label='PenguinAOSP',parts={k:dict(size=100663296 if k.startswith('boot') else 25165824,sha=v) for k,v in self.values.items() if k.startswith(("boot_","dtbo_"))})
 def push(self,p):self.values['uploaded']=m.digest(p);return 'uploaded'
 def sha(self,p):return self.values[p]
 def copy(self,s,t):
  self.calls.append(('copy',s,t))
  self.values[t]='e'*64 if t==self.fail_target else self.values[s]
 def zero(self,t,size):self.calls.append(('zero',t));self.values[t]=m.zero_digest(size)
 def reboot(self):self.calls.append(('reboot',))
 def pull_part(self,k,s,p):Path(p).write_bytes(b'short')

class Transactions(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.image_dir=tempfile.TemporaryDirectory();cls.image=Path(cls.image_dir.name)/'linux.img'
  with cls.image.open('wb') as f:f.truncate(100663296)
  cls.image_sha=m.digest(cls.image)
 @classmethod
 def tearDownClass(cls):cls.image_dir.cleanup()
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.phone=FakePhone();self.swap=m.Swap(self.phone,Path(self.tmp.name)/'state.json')
 def prepare(self):
  with patch.object(self.swap,'backup',return_value=Path(self.tmp.name)):
   self.swap.to_linux(self.image,self.image_sha)
 def test_round_trip_same_slot_and_only_two_partitions(self):
  self.prepare();self.assertEqual(self.phone.values['boot_a'],'a'*64);self.assertEqual(self.phone.values['dtbo_a'],'b'*64)
  self.assertEqual(self.phone.values['boot_b'],self.image_sha);self.assertEqual(self.phone.slot,'b')
  self.phone.mode='linux';self.phone.calls=[];self.swap.to_android()
  self.assertEqual(self.phone.values['boot_b'],'a'*64);self.assertEqual(self.phone.values['dtbo_b'],'b'*64)
  self.assertEqual(self.phone.slot,'b');self.assertEqual(self.phone.calls,[('copy','dtbo_a','dtbo_b'),('copy','boot_a','boot_b'),('reboot',)])
 def test_repeat_linux_cannot_overwrite_android_cache(self):
  self.prepare();before=copy.deepcopy(self.phone.values);self.phone.calls=[]
  with self.assertRaisesRegex(RuntimeError,'already prepared'):
   self.swap.to_linux(self.image,self.image_sha)
  self.assertEqual(self.phone.values,before);self.assertEqual(self.phone.calls,[])
 def test_corrupt_cache_refuses_restore_before_any_write(self):
  self.prepare();self.phone.mode='linux';self.phone.values['dtbo_a']='f'*64;self.phone.calls=[]
  with self.assertRaisesRegex(RuntimeError,'cache damaged'):self.swap.to_android()
  self.assertEqual(self.phone.calls,[])
 def test_backup_readback_failure_never_zeroes_active_or_reboots(self):
  self.phone.fail_target='boot_a'
  with patch.object(self.swap,'backup',return_value=Path(self.tmp.name)):
   with self.assertRaisesRegex(RuntimeError,'readback mismatch'):self.swap.to_linux(self.image,self.image_sha)
  self.assertEqual(self.phone.calls,[('copy','boot_b','boot_a')]);self.assertEqual(self.phone.values['dtbo_b'],'b'*64)
 def test_short_host_backup_aborts_before_any_write(self):
  with self.assertRaisesRegex(RuntimeError,'Short partition backup'):self.swap.to_linux(self.image,self.image_sha)
  self.assertEqual(self.phone.calls,[]);self.assertFalse(self.swap.state_path.exists())
 def test_wrong_slot_refuses_restore(self):
  self.prepare();self.phone.mode='linux';self.phone.slot='a';self.phone.calls=[]
  with self.assertRaisesRegex(RuntimeError,'slot differs'):self.swap.to_android()
  self.assertEqual(self.phone.calls,[])
 def test_interrupted_zero_can_restore_without_booting_linux(self):
  self.prepare();self.phone.values['boot_b']='a'*64;self.swap.phase('active_dtbo_zero');self.phone.calls=[]
  self.swap.to_android();self.assertEqual(self.phone.values['dtbo_b'],'b'*64)
  self.assertEqual(self.phone.values['boot_b'],'a'*64);self.assertEqual(self.phone.calls[-1],('reboot',))
 def test_dry_run_never_writes_or_creates_manifest(self):
  self.swap.to_linux(self.image,self.image_sha,dry_run=True)
  self.assertEqual(self.phone.calls,[]);self.assertFalse(self.swap.state_path.exists())

if __name__=='__main__':unittest.main()
