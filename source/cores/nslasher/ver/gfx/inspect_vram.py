#!/usr/bin/env python3
# Inspect the captured boot VRAM to understand the format before rendering.
import sys, os
d = os.path.dirname(os.path.abspath(__file__))
def load(name):
    out=[]
    for ln in open(os.path.join(d,name)):
        ln=ln.strip()
        if ln and not ln.startswith('//') and not ln.startswith('@'):
            out.append(int(ln,16))
    return out

pal  = load("vram_pal.hex")
pf   = {n: load("vram_pf%d.hex"%n) for n in (1,2,3,4)}
spr0 = load("vram_spr0.hex"); spr1 = load("vram_spr1.hex")
c12  = load("vram_ctl12.hex"); c34 = load("vram_ctl34.hex")
ace  = load("vram_ace.hex")

def nz(a): return sum(1 for v in a if v)
print("palette: %d entries, %d nonzero" % (len(pal), nz(pal)))
print("  first 8 nonzero (0x00BBGGRR):", [hex(v) for v in pal if v][:8])
for n in (1,2,3,4):
    a=pf[n]; high=sum(1 for v in a if v>>16)
    print("PF%d: %d nonzero, %d with high16 set; samples:"%(n,nz(a),high),
          [hex(v) for v in a if v][:10])
print("PF12 control (8w):", [hex(v) for v in c12])
print("PF34 control (8w):", [hex(v) for v in c34])
print("spr0 nonzero=%d  spr1 nonzero=%d"%(nz(spr0),nz(spr1)))
print("  spr0 first sprites (y,tile,x,?):")
for o in range(0,32,4):
    if spr0[o] or spr0[o+1] or spr0[o+2]:
        y,t,x=spr0[o],spr0[o+1],spr0[o+2]
        print("    [%03x] y=%08x t=%08x x=%08x  ->ypos=%d xpos=%d tile=%x col=%x"%(
            o,y,t,x,y&0x1ff,x&0x1ff,t&0xffff,(x>>9)&0x7f))
print("ace nonzero=%d  first 0x28:"%nz(ace), [hex(v) for v in ace[:0x28]])
