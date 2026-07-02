#!/usr/bin/env python3
# Dump every active sprite in f1800 spr0 (the complex 5bpp layer), decoded MAME-style,
# so we can see the multi-tile characters and their fields.
import os
caps="/path/to/nightslashers/mame-dump/caps"
spr=[int(l,16)&0xffff for l in open(os.path.join(caps,"f1800_spr0.hex")) if l.strip() and l[0] not in '/@']
print("idx offs  word0 word1 word2 | code  msz nt  fx fy flash colhi colour  sx   sy   (tilespan rows)")
for offs in range(0,0x400,4):
    y=spr[offs]; code=spr[offs+1]; x=spr[offs+2]
    if y==0 and code==0 and x==0: continue
    msz=(y&0x600)>>9; multi=(1<<msz)-1; nt=multi+1
    fx=1 if (y&0x2000) else 0; fy=1 if (y&0x4000) else 0
    flash=1 if (y&0x1000) else 0
    colour=(x>>9)&0x7f; colhi=1 if (y&0x8000) else 0
    if colhi: colour|=0x80
    sx=x&0x1ff; sy=y&0x1ff
    if sx>=320: sx-=512
    if sy>=256: sy-=512
    base=code&~multi
    # MAME: if !fy: sprite=base+multi, draws base+multi .. base (top tile = base+multi)
    print("%3d %4d  %04x  %04x  %04x | %5d  %d  %d   %d  %d   %d    %d    %3d   %4d %4d  rows %d..%d"%(
        offs//4,offs,y,code,x,code,msz,nt,fx,fy,flash,colhi,colour,sx,sy,sy,sy+16*nt-1))
