#!/usr/bin/env python3
# Compare jtnslasher_colmix RGB output (frame_rgb.hex, RRGGBB/line) vs the expected golden RGB
# (golden_pxl mapped through the palette the same way) -> the colmix bit-exactness check.
import os
d=os.path.dirname(os.path.abspath(__file__))
def load(n): return [l.strip() for l in open(os.path.join(d,n)) if l.strip() and l.strip()[0] not in '/@']
gp=[int(x,16) for x in load("golden_pxl.hex")]
pal=[int(x,16) for x in load("vram_pal.hex")]
rtl=[x for x in load("frame_rgb.hex")]
def expect(v):
    colour=(v>>4)&0xf; pix=v&0xf
    addr=0x200 if pix==0 else (0x100 | ((colour<<4)|pix))
    w=pal[addr] if addr<len(pal) else 0
    return "%02x%02x%02x"%(w&0xff,(w>>8)&0xff,(w>>16)&0xff)   # R G B
n=min(len(gp),len(rtl))
match=sum(1 for i in range(n) if rtl[i]==expect(gp[i]))
print("colmix RGB compare: %d/%d match (%.2f%%)"%(match,n,100.0*match/n))
mm=[i for i in range(n) if rtl[i]!=expect(gp[i])]
for i in mm[:8]:
    print("  px %d (pxl=%02x): rtl=%s expected=%s"%(i,gp[i],rtl[i],expect(gp[i])))
