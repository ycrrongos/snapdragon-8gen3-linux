"""ACM-only acceptance: WWAN DNS and HTTPS with Wi-Fi temporarily off."""
import pathlib,subprocess,sys,time
iface=sys.argv[1]
if iface not in ('cerro-sim2','qmapmux0.0'):raise SystemExit('unexpected WWAN interface')
# Refuse unless the independent physical console is bound to a USB host.
states=[p.read_text().strip() for p in pathlib.Path('/sys/class/udc').glob('*/state')]
if 'configured' not in states:raise SystemExit('USB recovery console not configured')
boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
try:
 subprocess.run(['nmcli','radio','wifi','off'],check=True,timeout=15,capture_output=True)
 if subprocess.check_output(['nmcli','radio','wifi'],text=True).strip()!='disabled':raise RuntimeError('Wi-Fi did not disable')
 print('Wi-Fi disabled; verifying carrier DNS and bound HTTPS',flush=True)
 subprocess.run([sys.executable,'/tmp/test-bound-data.py',iface],check=True,timeout=100)
finally:
 subprocess.run(['nmcli','radio','wifi','on'],check=True,timeout=15,capture_output=True)
 print('Wi-Fi re-enabled; same boot',pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()==boot,flush=True)
