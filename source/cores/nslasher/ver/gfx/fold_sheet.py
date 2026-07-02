#!/usr/bin/env python3
# ============================================================================
# Render obj0 sprite sheets: GOLDEN (correct) vs FOLD (what the real RTL fetches).
# Decodes each 16x16 tile from 40-bit half-row words and writes two PNGs.
#
#   sheet_golden.png : tiles decoded from gfx3_spr.hex (the validated render-format)
#   sheet_fold.png   : tiles decoded from fold_repro.fold_fetch() = the REAL
#                      .mra+download+FSM path (actual RTL: plane4 read [7:0]).
#
# A 40-bit word = {plane4[7:0],plane3,plane2,plane1,plane0}. For pixel column c
# (0=left) of the 8-px half-row, pen bit p = bit(7-c) of plane_p  (jtnslasher_obj
# line 16/134: plane p = byte p, bit7 leftmost). pen = 5-bit (0..31), 0=transparent.
# ============================================================================
import os, sys
import fold_repro as F      # reuses BA3/SDRAM/golden/fold_fetch (faithful model)
try:
    from PIL import Image
    HAVE_PIL = True
except Exception:
    HAVE_PIL = False

d = os.path.dirname(os.path.abspath(__file__))

# 32-entry pen palette: emphasise plane4 (bit4) as a hue shift so its loss is OBVIOUS.
# pens 0..15 = greyscale ramp (cool/blue tint), pens 16..31 = warm (red/yellow) ramp.
# pen 0 = transparent (rendered as a dark checkerboard background).
def pen_rgb(pen):
    if pen == 0: return None                       # transparent
    lo = pen & 0xF
    v  = 40 + lo*14                                 # 40..250
    if pen & 0x10:                                 # plane4 set -> warm
        return (v, v*7//16, 30)
    else:                                          # plane4 clear -> cool
        return (30, v*7//16, v)

def decode_tile(fetch, code):
    """Return a 16x16 list[row][col] of 5-bit pens for tile `code` using fetch(hra)."""
    px = [[0]*16 for _ in range(16)]
    for rowf in range(16):
        for half in range(2):                      # half=1 -> left 8px, half=0 -> right 8px (rom_addr half=fxd)
            hra = (code << 5) | (rowf << 1) | half
            w40 = fetch(hra)
            planes = [ (w40 >> (8*p)) & 0xff for p in range(5) ]
            # half=1 is the FIRST fetch (fxd=0 path: half=fxd=0 ... actually engine: half=fxd; rom half bit=fxd)
            # For an UNFLIPPED sprite fxd=~fx; with fx=0 -> fxd=1 -> half order: left half uses rom half-bit=1.
            # Map: rom_addr half bit = the half index; half==1 = left 8 columns, half==0 = right 8 columns.
            col0 = 0 if half == 1 else 8
            for c in range(8):
                pen = 0
                for p in range(5):
                    pen |= ((planes[p] >> (7-c)) & 1) << p
                px[rowf][col0 + c] = pen
    return px

def fetch_golden(hra):
    return F.golden.get(hra, 0)

def fetch_fold(hra):
    return F.fold_fetch(hra)

# ---- choose the code range to render: the golden clusters (Jake's tiles) ----
codes = sorted(set(h >> 5 for h in F.golden))
# Render the big cluster 0x4acb..0x4ae1 (Jake) plus the others, in a grid.
TILE = 16; SCALE = 4; PAD = 2
PER_ROW = 12
N = len(codes)
rows = (N + PER_ROW - 1) // PER_ROW
cellw = TILE*SCALE + PAD
cellh = TILE*SCALE + PAD + 10        # +label strip
W = PER_ROW*cellw + PAD
H = rows*cellh + PAD

def render_sheet(fetch, path, title):
    img = Image.new("RGB", (W, H), (18, 18, 24))
    px = img.load()
    # subtle checkerboard for transparent
    for y in range(H):
        for x in range(W):
            if ((x>>3) ^ (y>>3)) & 1:
                px[x, y] = (26, 26, 34)
    for idx, code in enumerate(codes):
        tile = decode_tile(fetch, code)
        cx = PAD + (idx % PER_ROW)*cellw
        cy = PAD + (idx // PER_ROW)*cellh
        for ry in range(16):
            for rx in range(16):
                rgb = pen_rgb(tile[ry][rx])
                if rgb is None: continue
                for sy in range(SCALE):
                    for sx in range(SCALE):
                        X = cx + rx*SCALE + sx; Y = cy + ry*SCALE + sy
                        if 0 <= X < W and 0 <= Y < H: px[X, Y] = rgb
    img.save(path)
    print("wrote", path, "(%dx%d, %d tiles, codes %#x..%#x)" % (W, H, N, min(codes), max(codes)))

def render_ppm(fetch, path):
    # PIL-free fallback
    buf = bytearray(W*H*3)
    for i in range(0, len(buf), 3):
        x=(i//3)%W; y=(i//3)//W
        c = (26,26,34) if (((x>>3)^(y>>3))&1) else (18,18,24)
        buf[i],buf[i+1],buf[i+2]=c
    for idx, code in enumerate(codes):
        tile = decode_tile(fetch, code)
        cx = PAD + (idx % PER_ROW)*cellw; cy = PAD + (idx // PER_ROW)*cellh
        for ry in range(16):
            for rx in range(16):
                rgb = pen_rgb(tile[ry][rx])
                if rgb is None: continue
                for sy in range(SCALE):
                    for sx in range(SCALE):
                        X=cx+rx*SCALE+sx; Y=cy+ry*SCALE+sy
                        if 0<=X<W and 0<=Y<H:
                            o=(Y*W+X)*3; buf[o],buf[o+1],buf[o+2]=rgb
    with open(path,"wb") as f:
        f.write(b"P6\n%d %d\n255\n"%(W,H)); f.write(bytes(buf))
    print("wrote", path)

if HAVE_PIL:
    render_sheet(fetch_golden, os.path.join(d, "sheet_golden.png"), "golden")
    render_sheet(fetch_fold,   os.path.join(d, "sheet_fold.png"),   "fold")
else:
    render_ppm(fetch_golden, os.path.join(d, "sheet_golden.ppm"))
    render_ppm(fetch_fold,   os.path.join(d, "sheet_fold.ppm"))

# Quantify the per-tile pen-loss (plane4 dropout) for the report
tot=0; lost=0
for code in codes:
    g=decode_tile(fetch_golden, code); fo=decode_tile(fetch_fold, code)
    for ry in range(16):
        for rx in range(16):
            if g[ry][rx]!=0:
                tot+=1
                if (g[ry][rx]&0x10) and not (fo[ry][rx]&0x10): lost+=1
print("plane4 (pen bit4) lost on %d / %d opaque pixels (%.1f%%) in the rendered Jake codes"
      % (lost, tot, 100.0*lost/max(tot,1)))
