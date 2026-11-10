from sms_pdu import submit,deliver,encode_address,normalize
# Synthetic, non-subscriber fixture; expected address nibble order is independent.
p=submit('+12025550123','测A')
assert p==bytes.fromhex('0001000b912120550521f30008046d4b0041')
# Standard SMS-DELIVER with empty SMSC and fixed synthetic seven-octet timestamp.
pdu=b'\0\0'+encode_address('+12025550123')+bytes([0,8])+bytes.fromhex('62110100000000')+bytes([4])+bytes.fromhex('6d4b0041')
assert deliver(pdu)==('12025550123','测A')
assert normalize('+86 138 0000 0000')==normalize('13800000000')
for bad in ('', '1', '+not a number'):
 try:submit(bad,'test')
 except ValueError:pass
 else:raise AssertionError('invalid recipient accepted')
try:submit('+12025550123','测'*71)
except ValueError:pass
else:raise AssertionError('multipart accepted')
print('SMS address/UCS2 submit/deliver/recipient/length fixtures passed')

# A network may deliver a domestic numeric originating address (TON=national).
national=b'\0\0'+bytes.fromhex('0ba13108000000f0')+bytes([0,8])+bytes.fromhex('62110100000000')+bytes([4])+bytes.fromhex('6d4b0041')
assert deliver(national)==('8613800000000','测A')
print('Domestic sender fixture passed')

from sms_pdu import decode_gsm7,GSM7
assert len(GSM7)==128
assert decode_gsm7(bytes.fromhex('e8329bfd06'),5)=='hello'
assert decode_gsm7(bytes([27|(20<<7)&255,20>>1]),2)=='^'
print('GSM7 default/extension fixtures passed')

from sms_pdu import submit_parts
parts=submit_parts('+12025550123','测'*80)
assert len(parts)==2 and all(p[1]==0x41 for p in parts)
# No UTF16 surrogate pair is split between concatenated message parts.
parts=submit_parts('+12025550123','😀'*40)
for p in parts:
    start=3+len(encode_address('+12025550123'))+3
    assert len(p[start:])<=140
    p[start+6:].decode('utf-16-be')
print('Concatenated UCS2 and surrogate boundary fixtures passed')
