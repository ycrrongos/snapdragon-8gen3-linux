#!/usr/bin/env python3
"""Initialize present USIMs before MM, without printing subscriber identifiers."""
import re,subprocess,time

def parse_state(raw):
    sessions={}
    for label in ('Primary GW','Secondary GW'):
        m=re.search(re.escape(label)+r":\s+slot '(\d+)', application '(\d+)'",raw)
        sessions[label]=tuple(map(int,m.groups())) if m else None
    slots={}
    for match in re.finditer(r'^Slot \[(\d+)\]:\n(.*?)(?=^Slot \[|\Z)',raw,re.M|re.S):
        slot=int(match[1]);body=match[2]
        if not re.search(r"Card state:\s*'present'",body):continue
        for app in re.finditer(r'^\s*Application \[(\d+)\]:\n(.*?)(?=^\s*Application \[|\Z)',body,re.M|re.S):
            if not re.search(r"Application type:\s*'usim",app[2]):continue
            aid=re.search(r'Application ID:\s*\n\s*([0-9A-Fa-f:]+)',app[2])
            state=re.search(r"Application state:\s*'([^']+)'",app[2])
            if aid:
                value=aid[1].replace(':','')
                if 10<=len(value)<=32 and len(value)%2==0:
                    slots[slot]={'app':int(app[1]),'aid':value,'state':state[1] if state else 'unknown'}
            break
    return sessions,slots

def query(option):
    result=subprocess.run(['qmicli','-d','qrtr://0',option],capture_output=True,text=True,timeout=12)
    if result.returncode:raise RuntimeError('QMI '+option.split('=')[0]+' failed')
    return result.stdout

def main():
    deadline=time.monotonic()+180;activated=set();last_error='UIM service unavailable'
    while time.monotonic()<deadline:
        try:
            raw=query('--uim-get-card-status')
            sessions,slots=parse_state(raw)
            present=len(re.findall(r"Card state:\s*'present'",raw))
            if len(slots)<present:
                last_error='present USIM applications not enumerated yet'
                time.sleep(.5);continue
            if not slots:
                print('cerro-cellular: no present USIM; allow ModemManager to report card status',flush=True)
                return
            desired=[(1,'Primary GW','primary-gw-provisioning'),(2,'Secondary GW','secondary-gw-provisioning')]
            # With only slot2 inserted, it becomes primary without powering off any slot.
            if 1 not in slots and 2 in slots:desired=[(2,'Primary GW','primary-gw-provisioning')]
            ready=True
            for slot,label,session in desired:
                if slot not in slots:continue
                app=slots[slot]
                if sessions[label]!=(slot,app['app']):
                    if slot not in activated:
                        query('--uim-change-provisioning-session=session-type='+session+',activate=yes,slot='+str(slot)+',aid='+app['aid'])
                        activated.add(slot)
                        print('cerro-cellular: USIM slot',slot,'provisioning activated',flush=True)
                    ready=False
                if app['state'] in ('detected','unknown','not-available','illegal'):ready=False
                elif app['state']!='ready':
                    print('cerro-cellular: slot',slot,'requires user unlock; no PIN attempted',flush=True)
            if ready:
                print('cerro-cellular: present USIM sessions initialized',flush=True);return
            last_error='USIM applications not initialized'
        except (RuntimeError,subprocess.TimeoutExpired):
            last_error='bounded UIM query/activation failed'
        time.sleep(.5)
    raise RuntimeError(last_error+' within hardware readiness window')

if __name__=='__main__':main()
