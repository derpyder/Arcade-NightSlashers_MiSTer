#!/usr/bin/env python3
# Golden for jtnslasher_obj: per-pixel sprite-layer MIX value {colour[7:0],pen} (16-bit), matching
# the line-buffer semantics (sprites back-to-front, write only where pen!=0, later overwrites).
# Emits golden_obj.hex (320x240, row-major) + obj_cfg.vh (BPP/SPRFILE/GFXFILE/MEMW) for tb_obj.v.
#   usage: gen_obj_golden.py <frame> <spr0|spr1>
import os, sys
frame=int(sys.argv[1]); layer=sys.argv[2]
d=os.path.dirname(os.path.abspath(__file__)); rom="/path/to/nightslashers/roms"
caps="/path/to/nightslashers/mame-dump/caps"
rd=lambda f: open(os.path.join(rom,f),'rb').read()
def hexf(n): return [int(l,16) for l in open(os.path.join(caps,"f%04d_%s.hex"%(frame,n))) if l.strip() and l[0] not in '/@']
def l16(reg,off,data):
    for i,b in enumerate(data): reg[off+i*2]=b
def l32(reg,off,data):
    for i,b in enumerate(data): reg[off+i*4]=b
if layer=="spr0":
    reg=bytearray(0xa00000); l16(reg,1,rd("mbh-02.14c")); l16(reg,0,rd("mbh-04.16c")); l16(reg,0x400001,rd("mbh-03.15c")); l16(reg,0x400000,rd("mbh-05.17c")); l32(reg,0x500000,rd("mbh-06.18c")); l32(reg,0x900000,rd("mbh-07.19c"))
    bpp=5; po=[(0xa00000//2)*8,16,0,24,8]; gfxf="gfx3_spr"
else:
    reg=bytearray(0x100000); l16(reg,1,rd("mbh-08.16e")); l16(reg,0,rd("mbh-09.18e"))
    bpp=4; po=[16,0,24,8]; gfxf="gfx4_spr"
XO=[64*8+i for i in range(8)]+[i for i in range(8)]; YO=[i*32 for i in range(16)]; INC=128*8
_c={}
def stile(code):
    if code in _c: return _c[code]
    base=code*INC; out=[[0]*16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            v=0
            for p in range(bpp):
                bit=base+po[p]+YO[y]+XO[x]; v|=((reg[bit>>3]>>(7-(bit&7)))&1)<<(bpp-1-p)
            out[y][x]=v
    _c[code]=out; return out
spr=hexf(layer); W,H=320,240
mix=[[0]*W for _ in range(H)]; maxtile=0
for offs in range(0,0x400,4):
    y=spr[offs]&0xffff; code=spr[offs+1]&0xffff; x=spr[offs+2]&0xffff
    colour=(x>>9)&0x7f
    if y&0x8000: colour|=0x80
    fx=0 if (y&0x2000) else 1; fy=0 if (y&0x4000) else 1
    multi=(1<<((y&0x600)>>9))-1
    sx=x&0x1ff; sy=y&0x1ff
    if sx>=320: sx-=512
    if sy>=256: sy-=512
    code&=~multi; inc=-1 if (y&0x4000) else 1
    if not (y&0x4000): code+=multi
    mh=(colour<<8); m=multi
    while m>=0:
        c0=code-m*inc; maxtile=max(maxtile,c0); px=stile(c0); ty=sy+16*m
        for ry in range(16):
            yy=ty+ry
            if 0<=yy<H:
                syc=15-ry if fy else ry
                for rx in range(16):
                    xx=sx+rx
                    if 0<=xx<W:
                        c=px[syc][15-rx if fx else rx]
                        if c: mix[yy][xx]=mh|c       # transparent skip; later (front) overwrites
        m-=1
open(os.path.join(d,"golden_obj.hex"),'w').write('\n'.join("%04x"%mix[y][x] for y in range(H) for x in range(W))+'\n')
memw=(maxtile*32)+32
with open(os.path.join(d,"obj_cfg.vh"),'w') as f:
    f.write("`define BPP %d\n`define MEMW %d\n"%(bpp,memw))
    f.write('`define SPRFILE "%s"\n`define GFXFILE "%s"\n'%(os.path.join(caps,"f%04d_%s.hex"%(frame,layer)).replace("\\","/"), os.path.join(d,gfxf+".hex").replace("\\","/")))
print("layer=%s frame=%d bpp=%d maxtile=%#x memw=%d -> golden_obj.hex + obj_cfg.vh"%(layer,frame,bpp,maxtile,memw))
