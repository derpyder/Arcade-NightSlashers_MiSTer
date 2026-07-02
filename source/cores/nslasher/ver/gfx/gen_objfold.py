#!/usr/bin/env python3
# Emit the FOLDED obj0 SDRAM image for the adapter render-sim (tb_objfold.v).
# Per nwi, an 8-byte slot = two 32-bit words:
#   word @(nwi*2)   = planes 0-3 native 32-bit word   (= obj0lo_native[nwi])
#   word @(nwi*2+1) = { 24'h0, plane4 }               (plane4 = obj0hi_native[nwi], at bits[7:0])
# Stored in HW byte-order (each 16-bit half byte-swapped) so the adapter's hwswap16() un-swaps to native,
# faithfully matching the real SDRAM delivery. Sparse @addr hex keyed by the 32-bit-word address.
import os
d = os.path.dirname(os.path.abspath(__file__))

def load_hex(name):
    out = {}; addr = 0
    for l in open(os.path.join(d, name)):
        l = l.strip()
        if not l: continue
        if l[0] == '@': addr = int(l[1:], 16); continue
        out[addr] = int(l, 16); addr += 1
    return out

lo_n = load_hex("obj0lo_native.hex")   # nwi -> native planes 32-bit word
hi_n = load_hex("obj0hi_native.hex")   # nwi -> native plane4 byte
o0   = load_hex("gfx3_spr.hex")        # hra -> 40-bit golden render word

def remap(hra):                        # hra = code*32 + rowf*2 + half -> nwi
    code = hra >> 5; rowf = (hra >> 1) & 0xf; half = hra & 1
    return code*32 + rowf + (0 if half else 16)

def hwswap16(x):                       # byte-swap each 16-bit half (HW SDRAM delivery order)
    return ((x >> 8) & 0x00FF00FF) | ((x << 8) & 0xFF00FF00)

words = {}
for nwi in lo_n:
    words[nwi*2]   = hwswap16(lo_n[nwi] & 0xFFFFFFFF)               # planes, HW-order
    words[nwi*2+1] = hwswap16(hi_n.get(nwi, 0) & 0xFF)             # {0,0,0,p4} -> HW-order

with open(os.path.join(d, "packed_objfold.hex"), "w") as f:
    for a in sorted(words):
        f.write("@%x\n%08x\n" % (a, words[a]))

# test vectors: (hra, golden40) for every golden tile -> two flat arrays the tb loops over
hras = sorted(o0)
with open(os.path.join(d, "tv_hra.hex"), "w") as f:
    for h in hras: f.write("%06x\n" % h)
with open(os.path.join(d, "tv_gold.hex"), "w") as f:
    for h in hras: f.write("%010x\n" % o0[h])

with open(os.path.join(d, "objfold_n.vh"), "w") as f:
    f.write("`define OBJFOLD_N %d\n" % len(hras))

print("emitted packed_objfold.hex : %d words (%d tiles), max word addr 0x%x"
      % (len(words), len(lo_n), max(words)))
print("emitted tv_hra.hex / tv_gold.hex / objfold_n.vh : %d test vectors" % len(hras))

