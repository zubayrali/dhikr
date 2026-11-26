#!/usr/bin/env python3
"""Decode Hermes v98 serialized object/array literals from the extracted Sabbih bundle.
Analysis helper only: treats bundle bytes as data."""
import json, struct, sys
from pathlib import Path
BASE=Path('/Users/fxwalken/Documents/GitHub/dhikr counter/research')
b=json.load(open(BASE/'sabbih-tasm/bundle.json'))
# hbctool strings preserve unicode values; Talaria hex-encodes UTF16 strings.
ss=json.load(open(BASE/'sabbih-hasm/string.json'))
STRINGS=[x['value'] for x in sorted(ss,key=lambda x:x['id'])]
LIT=bytes(b['literalValueBuffer'])
KEYS=bytes(b['objKeyBuffer'])
SHAPES=b['objShapeTable']

def parse_seq(buf, offset, total):
    pos=offset; out=[]
    remaining=total
    while remaining>0:
        if pos>=len(buf): raise ValueError(f'offset {offset} overran at {pos}, remaining {remaining}')
        tag=buf[pos]; pos+=1
        if tag & 0x80:
            left=((tag & 0x0f)<<8)|buf[pos]; pos+=1
        else:
            left=tag & 0x0f
        n=min(remaining,left)
        remaining-=n
        typ=tag & 0x70
        if typ==0x50: # short string
            for _ in range(n):
                v=struct.unpack_from('<H',buf,pos)[0]; pos+=2; out.append(('str',v,STRINGS[v] if v<len(STRINGS) else f'<bad {v}>'))
        elif typ==0x40: # long string
            for _ in range(n):
                v=struct.unpack_from('<I',buf,pos)[0]; pos+=4; out.append(('str',v,STRINGS[v] if v<len(STRINGS) else f'<bad {v}>'))
        elif typ==0x30: # double
            for _ in range(n):
                v=struct.unpack_from('<d',buf,pos)[0]; pos+=8; out.append(('num',v,v))
        elif typ==0x70: # integer
            for _ in range(n):
                v=struct.unpack_from('<i',buf,pos)[0]; pos+=4; out.append(('num',v,v))
        elif typ==0x00:
            out += [('null',None,None) for _ in range(n)]
        elif typ==0x10:
            out += [('bool',True,True) for _ in range(n)]
        elif typ==0x20:
            out += [('bool',False,False) for _ in range(n)]
        elif typ==0x60:
            out += [('undefined',None,None) for _ in range(n)]
        else:
            raise ValueError(f'unknown tag {tag:x} type {typ:x} at {pos-1}')
    return out,pos

def decode_object(shape_idx, val_off):
    sh=SHAPES[shape_idx]
    keys,kend=parse_seq(KEYS,sh['keyBufferOffset'],sh['numProps'])
    vals,vend=parse_seq(LIT,val_off,sh['numProps'])
    return {k[2]:v[2] for k,v in zip(keys,vals)}, keys, vals, sh, kend, vend

def decode_array(count, val_off):
    vals,end=parse_seq(LIT,val_off,count)
    return [v[2] for v in vals], vals, end

def fmt(x):
    return json.dumps(x,ensure_ascii=False,indent=2)

if __name__=='__main__':
    if sys.argv[1]=='obj':
        o,k,v,sh,ke,ve=decode_object(int(sys.argv[2]),int(sys.argv[3]))
        print('shape',sh,'key_end',ke,'val_end',ve)
        print(fmt(o))
        print('keys',fmt(k)); print('vals',fmt(v))
    elif sys.argv[1]=='arr':
        a,v,e=decode_array(int(sys.argv[2]),int(sys.argv[3]))
        print('end',e); print(fmt(a)); print('vals',fmt(v))
    elif sys.argv[1]=='shape':
        print(fmt(SHAPES[int(sys.argv[2])]))
