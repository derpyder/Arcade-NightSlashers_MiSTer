#!/usr/bin/env python3
# obj1/gfx4 unpack checker, rebuilt against the TRUE mame0284 region model.
#
# THE OLD check_obj1_unpack.py WAS THE SELF-CONSISTENT-TEST TRAP: it modeled the gfx4 region as
# 16-bit INTERLEAVED (mbh-08 odd / mbh-09 even, the 2009-driver style) — but pinned mame0284
# (deco32.cpp:3861-3862) loads them PLAIN SEQUENTIAL: mbh-08 @0x00000, mbh-09 @0x80000, and
# decodes with `tilelayout` (deco32.cpp:1824-1833): planeoff {RGN/2+8, RGN/2, 8, 0} = pen bits
# {3,2,1,0} = {mbh-09 odd, mbh-09 even, mbh-08 odd, mbh-08 even}. Validated against the wrong
# golden, the RTL's no-hwswap transform "passed 800/800" while swapping every pen's bit-pairs
# on real hardware: pen_ours = ((pen&3)<<2)|(pen>>2), e.g. shadow pen 0xE -> 0xB ->
# pal[0x60B]=00a6c3db = the EXACT warm tan (DB,C3,A6) the diag6 cab probe measured.
#
# This checker: golden = 0284 sequential region + tilelayout; as-built = the REAL .mra interleave16
# (mbh-08 map="01" even blob byte, mbh-09 map="10" odd) -> 32-bit LE word -> the RTL transform.
# Verdict must be: no-hwswap FAILS ; plane_permute(hwswap16()) PASSES (the nf26 FIX A).
import os

ROM = next(p for p in ["/path/to/nightslashers/roms", "/d/deck/fpga/nightslashers/roms",
                       "/path/to/nightslashers/roms"] if os.path.exists(p))
rd = lambda f: open(os.path.join(ROM, f), 'rb').read()
d8, d9 = rd("mbh-08.16e"), rd("mbh-09.18e")

# ---- GOLDEN: mame0284 region + tilelayout ----
REG = d8 + d9                       # sequential load, deco32.cpp:3861-3862
HALF_BIT = len(d8) * 8
PO = [HALF_BIT + 8, HALF_BIT, 8, 0] # pen bit 3..0
def gbit(a): return (REG[a >> 3] >> (7 - (a & 7))) & 1
def golden_tile(t):
    g = [[0]*16 for _ in range(16)]
    base = t * 512
    for r in range(16):
        for x in range(16):
            xo = 256 + x if x < 8 else x - 8
            v = 0
            for i, p in enumerate(PO):
                v |= gbit(base + r*16 + xo + p) << (3 - i)
            g[r][x] = v
    return g

# ---- AS-BUILT: .mra interleave16 blob (proven emission: map="01" part -> EVEN blob byte) ----
blob = bytearray(len(d8)*2)
blob[0::2] = d8                     # mbh-08 map="01" -> even
blob[1::2] = d9                     # mbh-09 map="10" -> odd
def word_LE(n):                     # obj1 32-bit read at word n (byte 4n), identity loader
    b = blob[4*n:4*n+4]
    return b[0] | (b[1]<<8) | (b[2]<<16) | (b[3]<<24)
def hwswap16(x): return (((x>>16)&0xff)<<24)|(((x>>24)&0xff)<<16)|((x&0xff)<<8)|((x>>8)&0xff)
def plane_permute(x): return (((x>>16)&0xff)<<24)|((x&0xff)<<16)|(((x>>24)&0xff)<<8)|((x>>8)&0xff)
def nwi(code,row,half): return (code<<5)|((0 if half else 1)<<4)|row
def extract_row(w0,w1):
    px=[0]*16
    for half,rw in ((0,w0),(1,w1)):
        for i in range(8):
            v=0
            for p in range(4): v |= ((rw>>(8*p+7-i))&1)<<p
            px[half*8+i]=v
    return px
def asbuilt_tile(code, use_hwswap):
    g=[]
    for r in range(16):
        ws=[]
        for h in (0,1):
            w = word_LE(nwi(code,r,h))
            if use_hwswap: w = hwswap16(w)
            ws.append(plane_permute(w))
        g.append(extract_row(ws[0],ws[1]))
    return g

# ---- sweep every non-blank tile ----
NT = len(REG)*8 // 512 // 2         # RGN_FRAC(1,2) tiles
res = {}
for mode, sw in (("no-hwswap (current RTL)", False), ("hwswap16 (FIX A)", True)):
    tot=bad=nz=0
    for t in range(0, NT, 3):       # stride-3 sweep
        g = golden_tile(t)
        if not any(any(row) for row in g): continue
        nz+=1
        a = asbuilt_tile(t, sw)
        for r in range(16):
            for x in range(16):
                tot+=1
                if g[r][x]!=a[r][x]: bad+=1
    res[mode]=(nz,tot,bad)
    print("%-26s : %d non-blank tiles, %d/%d px match  -> %s"
          % (mode, nz, tot-bad, tot, "PASS" if bad==0 else "FAIL"))
ok = res["no-hwswap (current RTL)"][2] > 0 and res["hwswap16 (FIX A)"][2] == 0
print("\nVERDICT: %s (no-hwswap must FAIL, hwswap16 must PASS)" % ("CONFIRMED" if ok else "UNEXPECTED"))
