from pathlib import Path
root=Path('/home/user/cerro-mm-build/sysroot/usr/lib/aarch64-linux-gnu')
runtime=Path('/usr/lib/aarch64-linux-gnu')
for p in root.glob('*.so'):
 if p.exists():continue
 candidates=list(runtime.glob(p.name+'.*'))
 if not candidates:continue
 # Only the already installed runtime is exposed in this isolated build directory.
 target=next((x for x in candidates if x.is_file()),None)
 if target:
  if p.is_symlink():p.unlink()
  p.symlink_to(target)
  print(p.name,'->',target.name)
