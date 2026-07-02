#!/usr/bin/env python3
# 7c-3d MRA download-check: does an MRA-assembled BA3 blob, after the IDENTITY download
# (jtnslasher_dwnld BA3) + the framework bank split (obj0lo @BA3+0 32b / obj0hi @BA3+0x800000 8b /
# obj1 @BA3+GFX4) + the jtnslasher_sdram at-fetch rewire, reproduce the PROVEN obj*_native.hex that
# the 7e sim used?  This is the one path 7e never exercised (sim loaded pre-split native hex).
#
# HW read model (from hdl/jtnslasher_sdram.v + the generated mister/jtnslasher_game_sdram.v):
#   nwi      = obj0_rom_addr -> {code, ~half, rowf}     (same index for lo+hi)
#   obj0lo[nwi] = BA3 32-bit word at byte nwi*4         (slot0, no offset)   little-endian
#   obj0hi[nwi] = BA3 byte at 0x800000 + nwi            (slot1, OBJ0HI_OFFSET=0x40_0000 words)
#   obj1[nwi]   = BA3 byte-word at GFX4 + nwi*4         (slot2, GFX4_OFFSET)
# The native hex already encode {obj0lo=word@nwi*4, obj0hi=g3[nwi*4+0x500000], obj1=word@nwi*4} of the
# MAME-native g3/g4.  So the test reduces to: which BA3 blob layout makes BA3[0x800000+nwi] == the
# golden obj0hi, and BA3[nwi*4..] == the golden obj0lo, for every used nwi.
import os
d = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", os.path.join(d, "..", "..", "..", "roms"))
rd = lambda f: open(os.path.join(ROM, f), 'rb').read()

# ---- MAME-native gfx3/gfx4 assembly (identical to down_pass.py g3/g4 = MAME ROM_START) ----
def l16(reg, off, data):
    for i, b in enumerate(data): reg[off + i*2] = b
def l32(reg, off, data):
    for i, b in enumerate(data): reg[off + i*4] = b
g3 = bytearray(0xa00000)
l16(g3, 1, rd("mbh-02.14c")); l16(g3, 0, rd("mbh-04.16c"))
l16(g3, 0x400001, rd("mbh-03.15c")); l16(g3, 0x400000, rd("mbh-05.17c"))
l32(g3, 0x500000, rd("mbh-06.18c")); l32(g3, 0x900000, rd("mbh-07.19c"))
g4 = bytearray(0x100000)
l16(g4, 1, rd("mbh-08.16e")); l16(g4, 0, rd("mbh-09.18e"))

# ---- load the proven native hex (the 7e sim inputs) : nwi -> value ----
def load_hex(name):
    out = {}; a = 0
    for l in open(os.path.join(d, name + ".hex")):
        l = l.strip()
        if not l: continue
        if l[0] == '@': a = int(l[1:], 16); continue
        out[a] = int(l, 16); a += 1
    return out
lo = load_hex("obj0lo_native"); hi = load_hex("obj0hi_native"); o1 = load_hex("obj1_native")

def rng(name, h, w):
    ks = sorted(h); print("  %-14s entries=%d  nwi=[%#x..%#x]  byte nwi*%d max=%#x"
                          % (name, len(ks), ks[0], ks[-1], w, ks[-1]*w))
print("=== native hex ranges (what the obj engine actually fetched) ===")
rng("obj0lo", lo, 4); rng("obj0hi", hi, 1); rng("obj1", o1, 4)

word = lambda reg, na: reg[na] | (reg[na+1] << 8) | (reg[na+2] << 16) | (reg[na+3] << 24)

# ---- sanity: confirm native == the MAME-native g3/g4 reads the down_pass emit claims ----
s_lo = all(lo[n] == word(g3, n*4)          for n in lo)
s_hi = all(hi[n] == g3[n*4 + 0x500000]     for n in hi)
s_o1 = all(o1[n] == word(g4, n*4)          for n in o1)
print("=== sanity vs MAME-native g3/g4 ===")
print("  obj0lo == g3 word@nwi*4         :", s_lo)
print("  obj0hi == g3[nwi*4 + 0x500000]  :", s_hi)
print("  obj1   == g4 word@nwi*4         :", s_o1)

# ---- does obj0lo's used range stay in the dense planes-0-3 zone (g3 0..0x4FFFFF)? ----
lo_max_byte = max(lo) * 4
print("=== obj0lo high-end ===")
print("  max obj0lo byte = %#x ; planes 0-3 dense end = 0x500000 ; spills into sparse plane-4 zone: %s"
      % (lo_max_byte, lo_max_byte >= 0x500000))

# ---- CANDIDATE MRA BLOB: obj0lo region = MAME g3 low 8MB (identity) ; obj0hi region = DENSE plane-4 ----
# dense plane-4 (what BA3[0x800000+nwi] must hold) = g3[0x500000 + 4*nwi] = mbh-06 ++ mbh-07 contiguous.
mbh06 = rd("mbh-06.18c"); mbh07 = rd("mbh-07.19c")
blob = bytearray(0xa00000)
blob[0:0x800000] = g3[0:0x800000]                      # obj0lo region = MAME g3 low 8 MB (identity)
dense = bytearray(mbh06 + mbh07)                        # obj0hi region = mbh-06 then mbh-07, contiguous
blob[0x800000:0x800000 + len(dense)] = dense

# model the HW reads off this blob
hw_lo = all(lo[n] == word(blob, n*4)          for n in lo)
hw_hi = all(hi[n] == blob[0x800000 + n]       for n in hi)
print("=== CANDIDATE blob = [g3 low 8MB][dense mbh06+mbh07 @0x800000] ===")
print("  HW obj0lo (word@nwi*4)      reproduces native:", hw_lo)
print("  HW obj0hi (byte@0x800000+nwi) reproduces native:", hw_hi)
# show the dense-plane-4 identity: g3[0x500000+4n] vs (mbh06++mbh07)[n]
dense_ok = all(g3[0x500000 + 4*n] == dense[n] for n in range(len(dense)))
print("  dense plane-4 == g3[0x500000+4n] for all n (mbh06++mbh07 contiguous):", dense_ok)

# ---- obj1/gfx4: obj1 region @ GFX4 ; obj1[nwi] = word@nwi*4 of g4 (native, identity) ----
hw_o1 = all(o1[n] == word(g4, n*4) for n in o1)
print("=== obj1 (gfx4) : identity g4 reproduces native:", hw_o1, "===")

print()
print("VERDICT: the MRA gfx3 region must be a CUSTOM split (NOT MAME ROM_START):")
print("  obj0lo (BA3 0..0x4FFFFF): planes 0-3 = mbh-02 LOAD16@1, mbh-04 LOAD16@0,")
print("          mbh-03 LOAD16@0x400001, mbh-05 LOAD16@0x400000  (obj0lo max read 0x4df7fc < 0x500000)")
print("  obj0hi (BA3 0x800000..)  : DENSE plane-4 = mbh-06 ++ mbh-07 CONTIGUOUS (plain LOAD)")
print("  -> mbh-06/07 go ONLY dense (obj0lo never reads the sparse zone, so no sparse copy needed).")
print("  -> NO RTL change: jtnslasher_dwnld BA3 identity is correct; the MRA does the dense gather.")
