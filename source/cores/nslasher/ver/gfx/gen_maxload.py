#!/usr/bin/env python3
# Synthetic WORST-CASE sprite load (the full-screen fire-effect shape) for the obj engine:
#   - 6 full-width layers of 128px-tall 16px columns (120 sprites live on lines 32-159)
#   - +7 single-tile sprites on lines 64-79  -> 127/line   (the parser-cap boundary, no clipping)
#   - +20 single-tile sprites on lines 96-111 -> 140/line  (exceeds the 127 cap -> frontmost lost)
# Emits ml_spr.hex (caps spriteram format), ml_gfx.hex (BPP=5 planar, dense nonzero pens = every
# pixel written), obj_cfg_maxload.vh. Consumed by tb_obj_maxload.v (run_obj_maxload.sh LAT sweep).
import os
d = os.path.dirname(os.path.abspath(__file__))

BPP = 5
NCODE = 32                      # small repeating tile set (flame tiles repeat in the real effect)

spr = [0x0180, 0, 0, 0] * 256   # park everything offscreen (y=0x180 -> inzone false), 256 x 4 words
si = 0
def put(y, code, x, colour, msz):
    global si
    spr[si*4+0] = (y & 0x1ff) | ((msz & 3) << 9)
    spr[si*4+1] = code & 0xffff
    spr[si*4+2] = (x & 0x1ff) | ((colour & 0x7f) << 9)
    spr[si*4+3] = 0
    si += 1

# 6 layers x 20 columns of 128px-tall sprites (msz=3, code aligned to 8): lines 32..159
for L in range(6):
    for col in range(20):
        put(32, ((L + col) % 4) * 8, col * 16, (L + col) & 0xf, 3)
# +7 on lines 64..79 -> exactly 127
for k in range(7):
    put(64, (k % NCODE) & ~0, k * 40, k & 0xf, 0)
# +20 on lines 96..111 -> 140 (cap-exceed region), placed LAST = frontmost = what clipping loses
for k in range(20):
    put(96, (k % NCODE), k * 16, (k + 3) & 0xf, 0)

print("sprites used: %d/256" % si)
open(os.path.join(d, "ml_spr.hex"), "w").write(
    "\n".join("0000%04x" % w for w in spr) + "\n")

# gfx: dense NONZERO pens everywhere (worst case: every pixel is a meaningful write)
words = []
for code in range(NCODE):
    for row in range(16):
        for half in range(2):
            w = 0
            for j in range(8):
                v = (((half * 8 + j) + row + code) & 0xf) | 0x10    # 5bpp pen 0x10-0x1f, never 0
                for p in range(BPP):
                    if (v >> p) & 1: w |= 1 << (8 * p + (7 - j))
            words.append(w)
open(os.path.join(d, "ml_gfx.hex"), "w").write(
    "\n".join("%010x" % w for w in words) + "\n")

open(os.path.join(d, "obj_cfg_maxload.vh"), "w").write(
    '`define BPP %d\n`define MEMW %d\n`define SPRFILE "ml_spr.hex"\n`define GFXFILE "ml_gfx.hex"\n'
    % (BPP, len(words)))
print("maxload: %d gfx words, cfg written" % len(words))
