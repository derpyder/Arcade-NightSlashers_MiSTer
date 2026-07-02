#!/usr/bin/env python3
# Compare jtnslasher_obj output (frame_obj.hex) vs golden (golden_obj.hex), 16-bit mix per pixel.
import os
d=os.path.dirname(os.path.abspath(__file__))
def L(n): return [int(x,16) for x in open(os.path.join(d,n)) if x.strip()]
g=L("golden_obj.hex"); r=L("frame_obj.hex"); W=320
n=min(len(g),len(r)); match=sum(1 for i in range(n) if g[i]==r[i])
gnz=sum(1 for v in g if v); rnz=sum(1 for v in r if v)
print("obj compare: %d/%d match (%.3f%%)  golden nonzero=%d  rtl nonzero=%d"%(match,n,100.0*match/n,gnz,rnz))
mm=[i for i in range(n) if g[i]!=r[i]]
for i in mm[:16]:
    print("  (%3d,%3d) golden=%04x rtl=%04x"%(i%W,i//W,g[i],r[i]))
