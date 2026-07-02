#!/usr/bin/env python3
import os,sys
d=os.path.dirname(os.path.abspath(__file__))
caps="/path/to/nightslashers/mame-dump/caps"; frame=int(sys.argv[1]) if len(sys.argv)>1 else 1800; layer=sys.argv[2] if len(sys.argv)>2 else "spr1"
def L(n): return [int(x,16) for x in open(os.path.join(d,n)) if x.strip()]
def cap(n): return [int(x,16) for x in open(os.path.join(caps,"f%04d_%s.hex"%(frame,n))) if x.strip()]
g=L("golden_obj.hex"); r=L("frame_obj.hex"); W=320
mm=[i for i in range(min(len(g),len(r))) if g[i]!=r[i]]
ymiss={}
for i in mm: ymiss[i//W]=ymiss.get(i//W,0)+1
print("mismatch rows (y:count):", dict(sorted(ymiss.items())))
g0=sum(1 for i in mm if g[i]!=0 and r[i]==0); r0=sum(1 for i in mm if r[i]!=0 and g[i]==0); bb=sum(1 for i in mm if r[i]!=0 and g[i]!=0)
print("golden-only(rtl missing)=%d  rtl-only(golden missing)=%d  both-diff=%d"%(g0,r0,bb))
# sprite list
spr=cap(layer)
print("--- %s sprites intersecting mismatch rows ---"%layer)
for offs in range(0,0x400,4):
    y=spr[offs]&0xffff; code=spr[offs+1]&0xffff; x=spr[offs+2]&0xffff
    colour=(x>>9)&0x7f|((0x80) if (y&0x8000) else 0)
    fx=0 if(y&0x2000) else 1; fy=0 if(y&0x4000) else 1; multi=(1<<((y&0x600)>>9))-1
    sx=x&0x1ff; sy=y&0x1ff
    if sx>=320: sx-=512
    if sy>=256: sy-=512
    h=16*(multi+1)
    if (sx<=40 and sx+16>0) or any(sy<=yy<sy+h for yy in ymiss):  # near the mismatch
        flag = " <==" if any(sy<=yy<sy+h for yy in ymiss) and sx<=40 else ""
        print("  offs%3x: x=%4d y=%4d code=%04x multi=%d fx=%d fy=%d colour=%02x rect=(%d..%d,%d..%d)%s"%(
            offs,sx,sy,code,multi,fx,fy,colour,sx,sx+15,sy,sy+h-1,flag))
