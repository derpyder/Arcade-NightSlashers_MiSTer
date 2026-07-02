#!/usr/bin/env python3
# Standalone golden + gfx generator for the IN-GAME frame f2700 (178 active sprites, many tall).
# Decisive experiment: render the settled (no-tear) OAM through the RTL obj engine and compare.
import os
ROM = "/path/to/nightslashers/roms"
CAPS = "/path/to/nightslashers/mame-dump/caps"
HERE = "/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx"

def rd(f): return open(ROM + "/" + f, "rb").read()
def hexf(fr, n):
    return [int(l, 16) for l in open(CAPS + "/f%04d_%s.hex" % (fr, n)) if l.strip() and l[0] not in '/@']
def l16(reg, off, data):
    for i, b in enumerate(data): reg[off + i*2] = b
def l32(reg, off, data):
    for i, b in enumerate(data): reg[off + i*4] = b

# obj0 / gfx3 5bpp layout (matches gen_obj_golden.py spr0 branch + reshuffle_spr.py)
reg = bytearray(0xa00000)
l16(reg, 1, rd("mbh-02.14c")); l16(reg, 0, rd("mbh-04.16c"))
l16(reg, 0x400001, rd("mbh-03.15c")); l16(reg, 0x400000, rd("mbh-05.17c"))
l32(reg, 0x500000, rd("mbh-06.18c")); l32(reg, 0x900000, rd("mbh-07.19c"))
bpp = 5; po = [(0xa00000//2)*8, 16, 0, 24, 8]
XO = [64*8+i for i in range(8)] + [i for i in range(8)]
YO = [i*32 for i in range(16)]; INC = 128*8

_c = {}
def stile(code):
    if code in _c: return _c[code]
    base = code*INC; out = [[0]*16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            v = 0
            for p in range(bpp):
                bit = base + po[p] + YO[y] + XO[x]
                v |= ((reg[bit>>3] >> (7-(bit&7))) & 1) << (bpp-1-p)
            out[y][x] = v
    _c[code] = out; return out

FRAME = 2700
spr = hexf(FRAME, "spr0"); W, H = 320, 240
mix = [[0]*W for _ in range(H)]; maxtile = 0
used = set()
for offs in range(0, 0x400, 4):
    y = spr[offs]&0xffff; code = spr[offs+1]&0xffff; x = spr[offs+2]&0xffff
    colour = (x>>9)&0x7f
    if y&0x8000: colour |= 0x80
    fx = 0 if (y&0x2000) else 1; fy = 0 if (y&0x4000) else 1
    multi = (1 << ((y&0x600)>>9)) - 1
    sx = x&0x1ff; sy = y&0x1ff
    if sx >= 320: sx -= 512
    if sy >= 256: sy -= 512
    code &= ~multi; inc = -1 if (y&0x4000) else 1
    if not (y&0x4000): code += multi
    mh = (colour<<8); m = multi
    while m >= 0:
        c0 = code - m*inc; maxtile = max(maxtile, c0); used.add(c0)
        px = stile(c0); ty = sy + 16*m
        for ry in range(16):
            yy = ty + ry
            if 0 <= yy < H:
                syc = 15-ry if fy else ry
                for rx in range(16):
                    xx = sx + rx
                    if 0 <= xx < W:
                        c = px[syc][15-rx if fx else rx]
                        if c: mix[yy][xx] = mh | c
        m -= 1

open(HERE + "/golden_obj_f2700.hex", "w").write(
    '\n'.join("%04x" % mix[y][x] for y in range(H) for x in range(W)) + '\n')

# emit the gfx hex for exactly the tiles f2700 uses, in tb_obj's reshuffled {code,row,half} layout
def tw(px, row, half):
    val = 0
    for i in range(8):
        v = px[row][half*8+i]
        for p in range(bpp):
            if (v>>p)&1: val |= (1 << (7-i)) << (8*p)
    return val
with open(HERE + "/gfx3_f2700.hex", "w") as f:
    for c in sorted(used):
        px = stile(c); f.write("@%x\n" % (c*32))
        for row in range(16):
            for half in range(2): f.write("%010x\n" % tw(px, row, half))

memw = (maxtile*32) + 32
with open(HERE + "/obj_cfg_f2700.vh", "w") as f:
    f.write("`define BPP 5\n`define MEMW %d\n" % memw)
    f.write('`define SPRFILE "%s"\n' % (CAPS + "/f%04d_spr0.hex" % FRAME))
    f.write('`define GFXFILE "%s"\n' % (HERE + "/gfx3_f2700.hex"))
print("f2700: active tiles=%d maxtile=%#x memw=%d -> golden_obj_f2700.hex + gfx3_f2700.hex" % (len(used), maxtile, memw))
