#!/usr/bin/env python3
# M3c — reshuffle decrypted gfx into the render-friendly PLANAR layout the RTL tilemap fetches
# (and the JTFRAME download pass will produce). Now generic over all three deco32 tile sets:
#
#   gfx1_tiles16  gfx1 (mbh-00) 16x16 -> PF2  (region 1)   [UNCHANGED; PF2 pipeline validated]
#   gfx1_chars8   gfx1 (mbh-00)  8x8  -> PF1  (region 0, the 8x8 text layer)
#   gfx2_tiles16  gfx2 (mbh-01) 16x16 -> PF3/PF4 (region 2)
#
# Planar word format (per 8 px): 32-bit word, 4 planes byte-interleaved, bit7=leftmost pixel.
#   pixel = { d[31], d[23], d[15], d[7] }  (plane3=MSB) ; shift left for next pixel.
#   16x16 tile = 16 rows x 2 halves -> byte addr = tile*128 + (row*2+half)*4
#    8x8  tile =  8 rows x 1 half   -> byte addr = tile* 32 +  row     *4
# Layouts/decode are the SAME tables decode_gfx.py validated by eye (font / cityscape / title).
import os, struct
d = os.path.dirname(os.path.abspath(__file__))

# ---- MAME planar tile decode (identical to decode_gfx.py) ----
def decode_tile(region, base_bit, planes, planeoff, xoff, yoff, w, h):
    px = [[0]*w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            v = 0
            for p in range(planes):
                bit = base_bit + planeoff[p] + yoff[y] + xoff[x]
                v |= ((region[bit >> 3] >> (7 - (bit & 7))) & 1) << (planes - 1 - p)
            px[y][x] = v
    return px

def charlayout_8x8(region):
    half = (len(region) * 8) // 2                       # RGN_FRAC(1,2)
    return dict(planes=4, planeoff=[half+8, half, 8, 0],
                xoff=[0,1,2,3,4,5,6,7], yoff=[i*16 for i in range(8)],
                inc=16*8, w=8, h=8, count=(len(region)//2)//16)

def tilelayout_16x16(region):
    half = (len(region) * 8) // 2
    return dict(planes=4, planeoff=[half+8, half, 8, 0],
                xoff=[32*8+i for i in range(8)] + [i for i in range(8)],
                yoff=[i*16 for i in range(16)],
                inc=64*8, w=16, h=16, count=(len(region)//2)//64)

# ---- generic reshuffle: decoded w x h 4bpp pixels -> planar 32-bit words (little-endian) ----
def reshuffle(region, lay):
    w, h, halves = lay['w'], lay['h'], lay['w'] // 8
    wpt = h * halves                                     # words per tile
    out = bytearray(lay['count'] * wpt * 4)
    for t in range(lay['count']):
        px = decode_tile(region, t*lay['inc'], lay['planes'], lay['planeoff'], lay['xoff'], lay['yoff'], w, h)
        for y in range(h):
            for half in range(halves):
                b = [0, 0, 0, 0]
                for i in range(8):
                    v = px[y][half*8 + i]
                    for p in range(4):
                        if (v >> p) & 1: b[p] |= 1 << (7 - i)   # bit7 = leftmost pixel
                word = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
                o = (t*wpt + y*halves + half) * 4
                out[o]=word&0xff; out[o+1]=(word>>8)&0xff; out[o+2]=(word>>16)&0xff; out[o+3]=(word>>24)&0xff
    return out

def emit(name, region, lay):
    out = reshuffle(region, lay)
    open(os.path.join(d, name+".bin"), 'wb').write(out)
    with open(os.path.join(d, name+".hex"), 'w') as f:
        for i in range(0, len(out), 4):
            f.write("%08x\n" % (out[i] | (out[i+1]<<8) | (out[i+2]<<16) | (out[i+3]<<24)))
    print("  %-14s %d tiles (%dx%d) -> %s.bin/.hex (%d bytes)" % (name, lay['count'], lay['w'], lay['h'], name, len(out)))
    return out

g1 = open(os.path.join(d, "gfx1_dec.bin"), 'rb').read()
g2 = open(os.path.join(d, "gfx2_dec.bin"), 'rb').read()

# regression: the PF2 16x16 set must stay byte-identical to the validated one on disk
prev = None
p = os.path.join(d, "gfx1_tiles16.bin")
if os.path.exists(p): prev = open(p, 'rb').read()

print("reshuffling deco32 tile sets:")
t16 = emit("gfx1_tiles16", g1, tilelayout_16x16(g1))   # PF2 (unchanged)
emit("gfx1_chars8",  g1, charlayout_8x8(g1))           # PF1 (NEW, 8x8)
emit("gfx2_tiles16", g2, tilelayout_16x16(g2))         # PF3/PF4 (NEW)

if prev is not None:
    print("REGRESSION gfx1_tiles16 vs prior on disk: %s" % ("IDENTICAL (PF2 pipeline intact)" if prev == t16 else "*** DIFFERS — investigate ***"))
print("done.")
