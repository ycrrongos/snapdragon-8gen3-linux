"""Regression tests for cold-boot readiness and preserving saved user intent."""
import ast,pathlib,threading
from unittest.mock import patch
import data_session

class Nas:
    def __init__(self):self.values=iter((b'\0\1\2',b'\1\1\2',b'\1\1\1'));self.queries=0;self.closed=False
    def bind(self,svc,sub):assert (svc,sub)==(3,2)
    def request(self,mid):assert mid==0x24;self.queries+=1;return {1:next(self.values)}
    def close(self):self.closed=True
nas=Nas()
with patch.object(data_session,'Client',return_value=nas),patch.object(data_session.time,'sleep'):
    data_session.DataSession().wait_packet_service(2)
assert nas.queries==3 and nas.closed

# Compile the real controller class without running its daemon entry point.
p=pathlib.Path(__file__).with_name('cellular_daemon.py');tree=ast.parse(p.read_text())
node=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='Controller')
commands=[]
def run(*args):commands.append(args);return ''
namespace={'run':run};exec(compile(ast.Module(body=[node],type_ignores=[]),str(p),'exec'),namespace)
Controller=namespace['Controller']
class Secondary:
    handle=None
    def connect(self):raise RuntimeError('injected transient cold-boot failure')
    def close(self):pass
    def dds(self,sub):pass
for bootstrap,expected in ((True,2),(False,1)):
    c=Controller.__new__(Controller);c.lock=threading.RLock();c.secondary=Secondary();c.slot=2;c.busy=False
    saves=[];c.save=lambda:saves.append(c.slot);commands.clear()
    try:c.select(2,bootstrap=bootstrap)
    except RuntimeError:pass
    else:raise AssertionError('failed connect reported success')
    assert c.slot==expected and not c.busy
    if bootstrap:
        assert saves==[]
        assert not any(cmd[-2:]==('up','cerro-sim1-cmnet') for cmd in commands)
    else:assert saves==[1]
print('Actual PS attach gate and bootstrap selection-preservation regressions passed')
