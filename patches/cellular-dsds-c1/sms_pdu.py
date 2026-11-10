"""Small single-part UCS2 3GPP SMS codec (TS 23.040). No network operations."""
import re

def normalize(number):
    value=re.sub(r'\D','',number)
    if not number.strip().startswith('+') and len(value)==11 and value.startswith('1'):value='86'+value
    if not re.fullmatch(r'\d{3,15}',value):raise ValueError('invalid subscriber number')
    return value

def encode_address(number):
    digits=normalize(number);padded=digits+('F' if len(digits)%2 else '')
    bcd=bytes(int(padded[i+1]+padded[i],16) for i in range(0,len(padded),2))
    return bytes([len(digits),0x91 if len(digits)>=7 else 0x81])+bcd

def submit(number,text):
    data=text.encode('utf-16-be')
    if not 0<len(data)<=140:raise ValueError('only single-part UCS2 is supported')
    return b'\0\x01\0'+encode_address(number)+bytes([0,8,len(data)])+data

def submit_parts(number,text):
    if len(text.encode('utf-16-be'))<=140:return [submit(number,text)]
    import secrets
    pieces=[];current=b''
    for char in text:
        value=char.encode('utf-16-be')
        if len(current)+len(value)>134:pieces.append(current);current=b''
        current+=value
    if current:pieces.append(current)
    if len(pieces)>12:raise ValueError('短信过长，请分次发送')
    ref=secrets.randbelow(256);result=[]
    for seq,part in enumerate(pieces,1):
        data=bytes([5,0,3,ref,len(pieces),seq])+part
        result.append(b'\0\x41\0'+encode_address(number)+bytes([0,8,len(data)])+data)
    return result

# 3GPP TS 23.038 default alphabet and extension table.
GSM7="@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
EXT={10:'\f',20:'^',40:'{',41:'}',47:'\\',60:'[',61:'~',62:']',64:'|',101:'€'}

def decode_gsm7(data,count,offset=0):
    output=[];escape=False;value=int.from_bytes(data,'little')
    for i in range(count):
        septet=(value>>(offset+i*7))&127
        if escape:output.append(EXT.get(septet,'�'));escape=False
        elif septet==27:escape=True
        else:output.append(GSM7[septet])
    return ''.join(output)

def deliver_details(pdu):
    pos=1+pdu[0]
    first=pdu[pos];pos+=1
    if first&3:raise ValueError('not SMS-DELIVER')
    digits=pdu[pos];ton=pdu[pos+1];pos+=2
    count=(digits+1)//2;raw=pdu[pos:pos+count];pos+=count
    sender=''.join(f'{b&15:x}{b>>4:x}' for b in raw)[:digits]
    if ton&0x70==0x50:sender=decode_gsm7(raw,digits*4//7)
    elif ton&0x70 in (0,0x10,0x20):sender=normalize(('+' if ton&0x70==0x10 else '')+sender)
    else:raise ValueError('unsupported sender type')
    pid,dcs=pdu[pos:pos+2];pos+=2
    stamp=pdu[pos:pos+7];pos+=7
    timestamp=0
    try:
        import datetime
        yy,month,day,hour,minute,second=[(b&15)*10+(b>>4) for b in stamp[:6]]
        quarter=(stamp[6]&7)*10+(stamp[6]>>4)
        zone=datetime.timezone(datetime.timedelta(minutes=quarter*15*(-1 if stamp[6]&8 else 1)))
        timestamp=datetime.datetime(2000+yy,month,day,hour,minute,second,tzinfo=zone).timestamp()
    except (ValueError,IndexError):pass
    length=pdu[pos];pos+=1
    data=pdu[pos:];header=0;concat=None
    if first&0x40:
        header=1+data[0];i=1
        while i+1<header:
            kind,size=data[i:i+2];part=data[i+2:i+2+size];i+=size+2
            if kind==0 and size==3:concat=(part[0],part[1],part[2])
            elif kind==8 and size==4:concat=(int.from_bytes(part[:2],'big'),part[2],part[3])
    if dcs&0x0c==8:
        if len(data)<length:raise ValueError('truncated UCS2 data')
        text=data[header:length].decode('utf-16-be')
    elif dcs&0x0c==0:
        header_septets=(header*8+6)//7
        text=decode_gsm7(data,length-header_septets,header_septets*7)
    else:text=data[header:length].decode('latin-1')
    return {'sender':sender,'text':text,'concat':concat,'time':timestamp}

def deliver(pdu):
    value=deliver_details(pdu)
    return value['sender'],value['text']
