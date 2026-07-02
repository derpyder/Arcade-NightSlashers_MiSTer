#!/usr/bin/env python3
# bio_align.py — empirical alignment scan for the joint-8bpp bio model.
# Renders the FULL joint PF3/4 pen plane (1024x512) + the PF1 text plane (512x256), then scans
# integer shifts to find the (dx,dy) minimizing pixel diff vs the MAME snapshot. Establishes the
# deco16ic scroll offset for this mode empirically (goldens must come from MAME, not the theory).
import os, sys, zlib, struct

frame = int(sys.argv[1]) if len(sys.argv)>1 else 3000
d    = os.path.dirname(os.path.abspath(__file__))
md   = "/path/to/nightslashers/mame-dump"
if not os.path.isdir(md): md = "/path/to/nightslashers/mame-dump"
caps = md + "/vancaps"
W,H  = 320,240

def hexf(n):
    return [int(l,16) for l in open(os.path.join(caps,"f%05d_%s.hex"%(frame,n))) if l.strip() and l[0] not in '/@']
snap=None
for l in open(caps+"/dumps.txt"):
    p=l.split()
    if p and p[0]=="f%05d"%frame: snap=md+"/vansnap2/nslashers/%s.png"%p[1].split('=')[1]

PALraw=hexf("pal")
pens=[( w&0xff,(w>>8)&0xff,(w>>16)&0xff) for w in PALraw]
def pen(i): return pens[i] if 0<=i<len(pens) else (255,0,255)

c12=hexf("ctl12"); c34=hexf("ctl34"); g=lambda L,i:(L[i]&0xffff) if i<len(L) else 0
def gbin(name): return open(os.path.join(d,name+".bin"),'rb').read()
GXC=gbin("gfx1_chars8"); GXT=gbin("gfx2_tiles16")
def gpix(gx,tile,y,x,t8):
    if t8: o=tile*32+y*4; k=7-x
    else:
        half=1 if x>=8 else 0; o=tile*128+(y*2+half)*4; k=7-(x&7)
    if o+4>len(gx): return 0
    w=gx[o]|(gx[o+1]<<8)|(gx[o+2]<<16)|(gx[o+3]<<24)
    return ((w>>k)&1)|(((w>>(8+k))&1)<<1)|(((w>>(16+k))&1)<<2)|(((w>>(24+k))&1)<<3)

def plane16(pfname, bankb):
    pf=hexf(pfname); out=[[0]*1024 for _ in range(512)]
    for row in range(32):
        for col in range(64):
            scan=(col&0x1f)+((row&0x1f)<<5)+((col&0x20)<<5)+((row&0x20)<<6)
            w=pf[scan]&0xffff; tile=(w&0xfff)|((bankb&~0xf)<<8); colour=(w>>12)&0xf
            for ty in range(16):
                for tx in range(16):
                    out[row*16+ty][col*16+tx]=(colour<<4)|gpix(GXT,tile,ty,tx,0)
    return out

pf3=plane16("pf3", g(c34,7)&0xff)
pf4=plane16("pf4",(g(c34,7)>>8)&0xff)
# joint pen plane (tm_bank0=2 -> p base 0x200 ; tm_bank1=3 -> p2 base 0x300)
joint=[[0]*1024 for _ in range(512)]
for y in range(512):
    r3=pf3[y]; r4=pf4[y]; rj=joint[y]
    for x in range(1024):
        p  = 0x200 | r3[x]
        p2 = 0x300 | r4[x]
        rj[x] = ((p & 0x70f) + (((p & 0x30) | (p2 & 0x0f)) << 4)) & 0x7ff

def rpng(path):
    sig=open(path,'rb').read(); i=8; w=h=ct=0; idat=b''
    while i<len(sig):
        ln=struct.unpack(">I",sig[i:i+4])[0]; typ=sig[i+4:i+8]; dat=sig[i+8:i+8+ln]; i+=12+ln
        if typ==b'IHDR': w,h,bd,ct=struct.unpack(">IIBB",dat[:10])
        elif typ==b'IDAT': idat+=dat
        elif typ==b'IEND': break
    raw=zlib.decompress(idat); ch=4 if ct==6 else 3; stride=w*ch; out=[]; prev=bytes(stride)
    pos=0
    def pa(a,b,c):
        p=a+b-c; pa_=abs(p-a); pb=abs(p-b); pc=abs(p-c)
        return a if (pa_<=pb and pa_<=pc) else (b if pb<=pc else c)
    for y in range(h):
        f=raw[pos]; line=bytearray(raw[pos+1:pos+1+stride]); pos+=1+stride
        for x in range(stride):
            a=line[x-ch] if x>=ch else 0; b=prev[x]; c=prev[x-ch] if x>=ch else 0
            if f==1: line[x]=(line[x]+a)&0xff
            elif f==2: line[x]=(line[x]+b)&0xff
            elif f==3: line[x]=(line[x]+((a+b)>>1))&0xff
            elif f==4: line[x]=(line[x]+pa(a,b,c))&0xff
        prev=bytes(line); out.append([(line[x*ch],line[x*ch+1],line[x*ch+2]) for x in range(w)])
    return w,h,out
sw,sh,sp=rpng(snap)

scrx,scry = g(c34,1)&0x3ff, g(c34,2)&0x1ff
best=(None,10**9)
for dy in range(-16,17):
    for dx in range(-16,17):
        bad=0; tot=0
        for y in range(0,H,4):
            sr=sp[y]
            jr=joint[(y+scry+dy)&0x1ff]
            for x in range(0,W,4):
                jp=jr[(x+scrx+dx)&0x3ff]
                m=sr[x]
                mod=pen(jp) if (jp&0xff) else None
                # compare only where the joint layer claims a pixel AND snapshot: count mismatch
                tot+=1
                if mod is None:
                    if m!=(0,0,0): bad+=1     # rough: backdrop unknown, penalize
                elif mod!=m: bad+=1
        if bad<best[1]: best=((dx,dy),bad)
print("joint best shift", best[0], "sparse mismatch", best[1], "of", tot)

# exact count at best shift
dx,dy=best[0]
bad=0
for y in range(H):
    sr=sp[y]; jr=joint[(y+scry+dy)&0x1ff]
    for x in range(W):
        jp=jr[(x+scrx+dx)&0x3ff]
        if jp&0xff and pen(jp)!=sr[x]: bad+=1
print("joint full mismatch (layer-claimed px only) at %s: %d"%((dx,dy),bad))
