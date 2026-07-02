#!/usr/bin/env python3
# ============================================================================
# Render FULL-RANGE obj0 sprite sheets: GOLDEN vs FOLD, across a representative
# code span (low working codes + high "garbled-on-HW" codes), so any data-path
# divergence is visible.  Uses fold_trace_all (real .mra + download + FSM).
#
#   sheet_all_golden.png : tiles from golden_fetch (ROM pixel-decode ground truth)
#   sheet_all_fold.png   : tiles from fold_fetch    (real .mra+download+FSM path)
#
# 40-bit word = {plane4, plane3, plane2, plane1, plane0}; pen bit p = bit(7-c)
# of plane_p; pen 0 = transparent.  Greyscale-by-pen palette (identity, not hue).
# ============================================================================
import os
import fold_trace_all as T
from PIL import Image

d = os.path.dirname(os.path.abspath(__file__))

# representative code span: a low block (works on HW) + several high blocks
# (walk/jump/enemy codes garbled on HW). Span sprites1a AND sprites1b regions.
GOLDEN_USED = sorted(set(h >> 5 for h in
    (lambda: [int(l[1:],16) for l in open(os.path.join(d,'gfx3_spr.hex')) if l.strip().startswith('@')])()))
codes = []
# 24 of the known-good golden (kick/portrait) codes
codes += GOLDEN_USED[:24]
# plus representative spans across the full range (incl. sprites1b boundary @0x8000)
for base in (0x0100, 0x1000, 0x2000, 0x4000, 0x4ac0, 0x7ff0, 0x8000, 0x9000, 0x9be0):
    codes += list(range(base, base+12))
codes = sorted(set(c for c in codes if c <= 0x9fff))

TILE=16; SCALE=3; PAD=2; PER_ROW=24
N=len(codes); rows=(N+PER_ROW-1)//PER_ROW
cellw=TILE*SCALE+PAD; cellh=TILE*SCALE+PAD
W=PER_ROW*cellw+PAD; H=rows*cellh+PAD

def pen_rgb(pen):
    if pen==0: return None
    # plane4 (bit4) -> warm tint so its presence/absence is visible; lo nibble -> brightness
    lo=pen&0xF; v=40+lo*14
    return (v, v*7//16, 30) if (pen&0x10) else (30, v*7//16, v)

def decode_tile(fetch, code):
    px=[[0]*16 for _ in range(16)]
    for rowf in range(16):
        for half in range(2):
            hra=(code<<5)|(rowf<<1)|half
            w40=fetch(hra)
            planes=[(w40>>(8*p))&0xff for p in range(5)]
            col0=0 if half==1 else 8
            for c in range(8):
                pen=0
                for p in range(5): pen|=((planes[p]>>(7-c))&1)<<p
                px[rowf][col0+c]=pen
    return px

def render(fetch, path, title):
    img=Image.new("RGB",(W,H),(18,18,24)); px=img.load()
    for y in range(H):
        for x in range(W):
            if ((x>>3)^(y>>3))&1: px[x,y]=(26,26,34)
    for idx,code in enumerate(codes):
        tile=decode_tile(fetch,code)
        cx=PAD+(idx%PER_ROW)*cellw; cy=PAD+(idx//PER_ROW)*cellh
        for ry in range(16):
            for rx in range(16):
                rgb=pen_rgb(tile[ry][rx])
                if rgb is None: continue
                for sy in range(SCALE):
                    for sx in range(SCALE):
                        X=cx+rx*SCALE+sx; Y=cy+ry*SCALE+sy
                        if 0<=X<W and 0<=Y<H: px[X,Y]=rgb
    img.save(path)
    print("wrote %s (%dx%d, %d tiles, codes %#x..%#x)"%(path,W,H,N,min(codes),max(codes)))

render(T.golden_fetch, os.path.join(d,"sheet_all_golden.png"), "golden")
render(T.fold_fetch,   os.path.join(d,"sheet_all_fold.png"),   "fold")

# pixel-exact diff over the rendered span
diff=0; tot=0
for code in codes:
    g=decode_tile(T.golden_fetch,code); f=decode_tile(T.fold_fetch,code)
    for ry in range(16):
        for rx in range(16):
            tot+=1
            if g[ry][rx]!=f[ry][rx]: diff+=1
print("rendered-span pixel diff golden-vs-fold: %d / %d (%.3f%%)"%(diff,tot,100.0*diff/tot))
