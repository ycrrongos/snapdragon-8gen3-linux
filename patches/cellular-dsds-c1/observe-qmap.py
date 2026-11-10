#!/usr/bin/env python3
"""Read only QMAP header metadata, never log/store IP or SMS payload."""
import collections,socket,struct,sys,time
iface=sys.argv[1];duration=float(sys.argv[2])
s=socket.socket(socket.AF_PACKET,socket.SOCK_RAW,socket.htons(3));s.bind((iface,0));s.settimeout(.5)
counts=collections.Counter();end=time.monotonic()+duration
while time.monotonic()<end:
 try:data,addr=s.recvfrom(65536)
 except socket.timeout:continue
 if len(data)>=4:
  flags,mux,length=struct.unpack('!BBH',data[:4])
  counts[(addr[2],flags,mux,length)]+=1
s.close()
for key,count in sorted(counts.items()):print('packet_type flags mux payload_length count',*key,count)
