#!/usr/bin/env python3
# DECISIVE obj1 (gfx4) static-path check: does the RTL unpack
#     obj1_rom_data = plane_permute(hwswap16(obj1_data))
# turn the SDRAM dword (== native gfx4 dword, proven by validate_fold_mra.py) into the
# render word the obj engine needs (== reshuffle_spr tileword golden, proven by tb_obj)?
#
#   engine rom_addr hra = {code,row[3:0],half}; RTL nwi = {code, ~half, row} ;
#   SDRAM dword at nwi (LE bytes g4[4*nwi..4*nwi+3])
#   expected: byte p = plane p (plane0=LSB byte), bit 7-i = pixel i of the 8-px half-row
import os, sys
def _first(*c):
    for p in c:
        if os.path.isdir(p): return p
    return c[0]
rom  = _first("/path/to/nightslashers/roms", "/path/to/nightslashers/roms",
              "/d/deck/fpga/nightslashers/roms")
caps = _first("/path/to/nightslashers/mame-dump/caps", "/path/to/nightslashers/mame-dump/caps",
              "/d/deck/fpga/nightslashers/mame-dump/caps")
frame = int(sys.argv[1]) if len(sys.argv) > 1 else 6000
rd = lambda f: open(os.path.join(rom, f), 'rb').read()

g4 = bytearray(0x100000)
d8 = rd("mbh-08.16e"); d9 = rd("mbh-09.18e")
for i, b in enumerate(d8): g4[1 + i*2] = b      # odd bytes
for i, b in enumerate(d9): g4[0 + i*2] = b      # even bytes

# ---- MAME pixel decode (spritelayout 4bpp, po MSB-first {16,0,24,8}) ----
XO = [64*8+i for i in range(8)] + [i for i in range(8)]
YO = [i*32 for i in range(16)]
INC = 128*8
PO = [16, 0, 24, 8]
def stile(code):
    base = code*INC
    out = [[0]*16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            v = 0
            for p in range(4):
                bit = base + PO[p] + YO[y] + XO[x]
                v |= ((g4[bit >> 3] >> (7-(bit & 7))) & 1) << (3-p)
            out[y][x] = v
    return out
def tileword(px, row, half):   # expected render word: plane p = byte p, bit7-i = px i
    val = 0
    for i in range(8):
        v = px[row][half*8 + i]
        for p in range(4):
            if (v >> p) & 1: val |= (1 << (7-i)) << (8*p)
    return val

# ---- RTL unpack ----
def hwswap16(d):
    return ((d & 0x00FF0000) | ((d >> 8) & 0x00FF00FF) << 16 | 0) # placeholder, real below
def hwswap16(d):  # { d[23:16], d[31:24], d[7:0], d[15:8] }
    return (((d >> 16) & 0xFF) << 24) | (((d >> 24) & 0xFF) << 16) | ((d & 0xFF) << 8) | ((d >> 8) & 0xFF)
def plane_permute(d):  # { d[23:16], d[7:0], d[31:24], d[15:8] }
    return (((d >> 16) & 0xFF) << 24) | ((d & 0xFF) << 16) | (((d >> 24) & 0xFF) << 8) | ((d >> 8) & 0xFF)

def native_dword(nwi):
    o = nwi*4
    return g4[o] | (g4[o+1] << 8) | (g4[o+2] << 16) | (g4[o+3] << 24)

# ---- used tiles from the captured frame's spr1 ----
def hexf(n): return [int(l,16) for l in open(os.path.join(caps,"f%04d_%s.hex"%(frame,n))) if l.strip() and l[0] not in '/@']
spr = hexf("spr1")
used = set()
for offs in range(0, 0x400, 4):
    y = spr[offs] & 0xffff; code = spr[offs+1] & 0xffff
    multi = (1 << ((y & 0x600) >> 9)) - 1
    base = code & ~multi
    sx = spr[offs+2] & 0x1ff; sy = y & 0x1ff
    if sx >= 320: sx -= 512
    if sy >= 256: sy -= 512
    if sy >= 240 and sy < 256: continue
    for k in range(multi+1): used.add((base+k) & 0x1fff)
used = sorted(used)
print("frame %d: %d used gfx4 tiles" % (frame, len(used)))

bad = tot = 0
for code in used:
    px = stile(code)
    for row in range(16):
        for half in range(2):
            nwi = (code << 5) | ((0 if half else 1) << 4) | row
            # RTL (nf5): obj1_rom_data = plane_permute(obj1_data)  -- NO hwswap16 (the .mra delivers gfx4
            # NATIVE; the stale hwswap scrambled gfx4/shadows). Proven: no-hwswap=800/800, hwswap=FAIL.
            got = plane_permute(native_dword(nwi))
            exp = tileword(px, row, half)
            tot += 1
            if got != exp:
                bad += 1
                if bad <= 8:
                    print("MISMATCH code=%04x row=%d half=%d nwi=%05x  raw=%08x got=%08x exp=%08x"
                          % (code, row, half, nwi, native_dword(nwi), got, exp))
print("RESULT: %d/%d match, %d bad -> %s" % (tot-bad, tot, bad, "PASS" if bad == 0 else "FAIL"))
