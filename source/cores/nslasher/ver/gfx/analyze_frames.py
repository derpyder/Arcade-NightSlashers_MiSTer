#!/usr/bin/env python3
# Scan every captured frame's sprite RAM (spr0 = gfx3/5bpp layer) MAME-style and report,
# per frame: total active sprites, multi-tile (msz>0) sprites, the busiest scanline and
# how many 16x16 *tiles* land on it (vs the RTL's per-line cap of 40), so we can pick a
# frame with a big multi-tile character that would expose the engine bug.
import os, sys
caps="/path/to/nightslashers/mame-dump/caps"
FRAMES=[1,120,240,360,480,600,720,900,1080,1200,1500,1800]
H=240
def load(frame,layer):
    p=os.path.join(caps,"f%04d_%s.hex"%(frame,layer))
    return [int(l,16)&0xffff for l in open(p) if l.strip() and l[0] not in '/@']
def analyze(frame,layer):
    spr=load(frame,layer)
    tiles_per_line=[0]*H
    active=0; multi_cnt=0; biggest=0
    details=[]
    for offs in range(0,0x400,4):
        y=spr[offs]; code=spr[offs+1]; x=spr[offs+2]
        # MAME flash skip not modeled (frame parity); count geometry
        msz=(y&0x600)>>9
        multi=(1<<msz)-1
        sx=x&0x1ff; sy=y&0x1ff
        if sx>=320: sx-=512
        if sy>=256: sy-=512
        # a sprite is "present" if any tile column lands on screen rows
        nt=multi+1
        # vertical span sy..sy+16*nt-1
        present=False
        for m in range(nt):
            ty=sy+16*m
            for ry in range(16):
                yy=ty+ry
                if 0<=yy<H:
                    tiles_per_line[yy]+=1
                    present=True
        if present:
            active+=1
            if msz>0:
                multi_cnt+=1
                biggest=max(biggest,nt)
                details.append((offs,sx,sy,code,nt,msz))
    busy=max(tiles_per_line)
    busy_line=tiles_per_line.index(busy)
    over40=sum(1 for t in tiles_per_line if t>40)
    return active,multi_cnt,biggest,busy,busy_line,over40,details
print("layer spr0 (gfx3, 5bpp):")
print("frame  active  multi  maxTiles  busiestLine(tiles)  linesOver40")
best=None
for f in FRAMES:
    a,mc,big,busy,bl,o40,det=analyze(f,"spr0")
    flag=" <== OVER CAP" if o40>0 else ""
    print("%5d  %5d  %5d  %7d  line %3d (%2d tiles)  %3d%s"%(f,a,mc,big,bl,busy,o40,flag))
print()
print("layer spr1 (gfx4, 4bpp):")
print("frame  active  multi  maxTiles  busiestLine(tiles)  linesOver40")
for f in FRAMES:
    a,mc,big,busy,bl,o40,det=analyze(f,"spr1")
    flag=" <== OVER CAP" if o40>0 else ""
    print("%5d  %5d  %5d  %7d  line %3d (%2d tiles)  %3d%s"%(f,a,mc,big,bl,busy,o40,flag))
