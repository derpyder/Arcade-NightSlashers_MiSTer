#!/usr/bin/env python3
# Compare the full-frame video sim (tb_video2 -> frame2_rgb.hex, raw 384-wide, hdump-indexed)
# against ref_render's golden (cm_rgb.hex, 320x240). Sweeps the pipeline offset (dx for the line-buffer
# + colmix latency, dy for the vrender lead) and reports the best match; 76800/76800 == bit-exact.
import os, sys
d=os.path.dirname(os.path.abspath(__file__))
W,H,HW=320,240,384
fbfile = sys.argv[1] if len(sys.argv)>1 else "frame2_rgb.hex"
def load(p): return [int(l,16) for l in open(os.path.join(d,p)) if l.strip()]
fb=load(fbfile); gold=load("cm_rgb.hex")
assert len(gold)==W*H, "golden size %d"%len(gold)
assert len(fb)==HW*H,  "fb size %d"%len(fb)

best=(-1,0,0)
for dy in (-1,0,1):
    for dx in range(-3,5):
        n=m=0
        for y in range(H):
            yy=y+dy
            if yy<0 or yy>=H: continue
            base=yy*HW
            for x in range(W):
                xx=x+dx
                if xx<0 or xx>=HW: continue
                n+=1
                if gold[y*W+x]==fb[base+xx]: m+=1
        if m>best[0]: best=(m,dx,dy)
m,dx,dy=best
print("best offset dx=%+d dy=%+d : %d/%d match (%.3f%%)"%(dx,dy,m,W*H,100.0*m/(W*H)))

# first mismatch at the best offset
for y in range(H):
    yy=y+dy
    if yy<0 or yy>=H: continue
    for x in range(W):
        xx=x+dx
        if 0<=xx<HW and gold[y*W+x]!=fb[yy*HW+xx]:
            print("  first mismatch (x=%d,y=%d): rtl=%06x golden=%06x"%(x,y,fb[yy*HW+xx],gold[y*W+x]))
            raise SystemExit(0 if m==W*H else 1)
print("video compare: %d/76800 match%s"%(m,"  BIT-EXACT" if m==W*H else ""))
raise SystemExit(0 if m==W*H else 1)
