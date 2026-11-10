from prepare_dual_usim import parse_state
raw="""Provisioning applications:
 Primary GW: slot '1', application '2'
 Secondary GW: session doesn't exist
Slot [1]:
 Card state: 'present'
 Application [1]:
  Application type: 'isim (5)'
  Application state: 'ready'
  Application ID:
   A0:00:00:00:01
 Application [2]:
  Application type: 'usim (2)'
  Application state: 'ready'
  Application ID:
   A0:00:00:00:02
Slot [2]:
 Card state: 'present'
 Application [1]:
  Application type: 'usim (2)'
  Application state: 'detected'
  Application ID:
   A0:00:00:00:03
"""
sessions,slots=parse_state(raw)
assert sessions=={'Primary GW':(1,2),'Secondary GW':None}
assert slots[1]['app']==2 and slots[1]['aid']=='A000000002' and slots[1]['state']=='ready'
assert slots[2]['state']=='detected'
assert parse_state(raw.replace("Card state: 'present'","Card state: 'absent'"))[1]=={}
print('USIM app selection, readiness, absent card and per-session mapping fixtures passed')
