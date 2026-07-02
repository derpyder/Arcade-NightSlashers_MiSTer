#!/usr/bin/env python3
# Dump the PF2 tilemap as a 64x32 grid (which cells have tiles) to see the logo's footprint
# and whether the "T" tiles exist in the captured data.
import os
d=os.path.dirname(os.path.abspath(__file__))
def load(n): return [int(l.strip(),16) for l in open(os.path.join(d,n)) if l.strip() and l.strip()[0] not in '/@']
pf2=load("vram_pf2.hex")
def scan(c,r): return (c&0x1f)+((r&0x1f)<<5)+((c&0x20)<<5)+((r&0x20)<<6)
print("   " + "".join(str(c//10%10) for c in range(64)))
print("   " + "".join(str(c%10) for c in range(64)))
minc,maxc,minr,maxr=99,-1,99,-1
for r in range(32):
    line=""
    for c in range(64):
        t=pf2[scan(c,r)]&0xfff
        if t: line+="#"; minc=min(minc,c);maxc=max(maxc,c);minr=min(minr,r);maxr=max(maxr,r)
        else: line+="."
    if "#" in line: print("%2d %s"%(r,line))
print("nonzero tile bounding box: cols %d..%d  rows %d..%d"%(minc,maxc,minr,maxr))
print("screen (scroll 256,256) covers map cols 16..35, rows 16..30")
