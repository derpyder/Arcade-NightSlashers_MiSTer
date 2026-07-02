#!/usr/bin/env python3
# FAITHFUL preload + test-vectors for tb_objfold_real.v.
#
# Unlike gen_objfold_combined*.py (which COMPACT-REMAP every tile to a dense nwi 0,1,2,... so the real
# 21-bit nwi / bcache tag / line-eviction behaviour is NEVER exercised), this generator places each tile
# at its REAL SDRAM address: planes 32-bit word @ nwi*2, plane4 32-bit word @ nwi*2+1, i.e. SDRAM 16-bit
# words nwi*4..nwi*4+3.  The engine address driven into the FSM is the REAL hra (obj0_rom_addr); the FSM
# permutation nwi={a[20:5],~a[0],a[4:1]} reproduces the real nwi, and remap_native_nwi(hra)==fsm_nwi(hra)
# (verified) so lo_n/hi_n are indexed by the real nwi too.
#
# One mt48lc16m16a2 bank = 4M x 16 = 0x3FFFFF words, so we keep only tiles whose top SDRAM word
# nwi*4+3 < 0x400000 (nwi < 0x100000).  That is ~768 of 1440 tiles and still spans real nwi up to
# ~0xFFFFF (20 real address bits) -> real high-order tags + real bcache lines.
#
# We ALSO emit the tiles in an order that drives the engine BACK-TO-BACK as half-0/half-1 PAIRS
# (consecutive hra differing in bit0), the real jtnslasher_obj draw cadence, so the 2-line bcache
# eviction + DOUBLE flip + the FSM cs-toggle / fresh-ok edge detect are stressed under OKLATCH=1 at
# real burst latency across adjacent tiles.

import os
D   = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.join(D, "..", "gfx")

def load_hex(path):
    out = {}; addr = 0
    for l in open(path):
        l = l.strip()
        if not l: continue
        if l[0] == '@': addr = int(l[1:], 16); continue
        out[addr] = int(l, 16); addr += 1
    return out

lo_n = load_hex(os.path.join(GFX, "obj0lo_native.hex"))   # nwi -> native planes 32-bit word
hi_n = load_hex(os.path.join(GFX, "obj0hi_native.hex"))   # nwi -> native plane4 byte
o0   = load_hex(os.path.join(GFX, "gfx3_spr.hex"))         # hra -> 40-bit golden render word

def fsm_nwi(a):                            # the FSM permutation nwi={a[20:5],~a[0],a[4:1]}
    return ((a >> 5) << 5) | ((0 if (a & 1) else 1) << 4) | ((a >> 1) & 0xf)

def hwswap16(x):                           # byte-swap each 16-bit half (HW SDRAM delivery order)
    return ((x >> 8) & 0x00FF00FF) | ((x << 8) & 0xFF00FF00)

BANK_CAP = 0x400000                        # one mt48lc16m16a2 = 4M 16-bit words

# Keep tiles whose REAL placement fits the bank, sorted by hra (so half-0/half-1 pairs are adjacent:
# hras for a given (code,row) differ only in bit0 and sort consecutively).
hras = sorted(h for h in o0 if fsm_nwi(h)*4 + 3 < BANK_CAP)

sdram   = {}                               # 16-bit SDRAM word address -> 16-bit value (sparse, REAL addr)
tv_addr = []
tv_gold = []

for hra in hras:
    nwi    = fsm_nwi(hra)
    planes = hwswap16(lo_n.get(nwi, 0) & 0xFFFFFFFF)   # HW-order planes word
    p4word = (hi_n.get(nwi, 0) & 0xFF) << 8            # plane4 in HIGH byte (.mra map="10"); FSM reads o0_p4word[15:8]
    base   = nwi * 4                                    # REAL SDRAM 16-bit word base (NOT compacted)
    sdram[base+0] = planes & 0xFFFF
    sdram[base+1] = (planes >> 16) & 0xFFFF
    sdram[base+2] = p4word & 0xFFFF
    # FAITHFULNESS: the download (jtnslasher_dwnld.v) writes the plane4 16-bit word to 4nwi+2 ONLY;
    # it NEVER writes 4nwi+3 (the high half of the plane4 32-bit DOUBLE word). On HW that SDRAM word
    # holds stale/garbage. Default 0 (matches a fresh bank); GARBAGE_HI=1 stuffs a non-zero pattern
    # there to PROVE the FSM's [7:0] plane4 extraction is immune to the unwritten high half.
    if os.environ.get("GARBAGE_HI") == "1":
        sdram[base+3] = (0xDEAD ^ (nwi & 0xFFFF)) & 0xFFFF      # deterministic garbage at 4nwi+3
    else:
        sdram[base+3] = (p4word >> 16) & 0xFFFF                 # = 0 (plane4 is a byte)
    tv_addr.append(hra)
    tv_gold.append(o0[hra])

# flat 16-bit-per-word sparse @-addressed image for the mt48lc16m16a2 Bank3 $readmemh
with open(os.path.join(D, "sdram_bank3_real.hex"), "w") as f:
    prev = None
    for a in sorted(sdram):
        if a != prev:
            f.write("@%X\n" % a)
        f.write("%04X\n" % sdram[a])
        prev = a + 1

with open(os.path.join(D, "objfold_real_addr.hex"), "w") as f:
    for a in tv_addr: f.write("%06x\n" % a)
with open(os.path.join(D, "objfold_real_gold.hex"), "w") as f:
    for g in tv_gold: f.write("%010x\n" % g)
with open(os.path.join(D, "objfold_real_n.vh"), "w") as f:
    f.write("`define OBJFOLD_N %d\n" % len(hras))

maxw = max(sdram) if sdram else 0
maxnwi = max(fsm_nwi(h) for h in hras) if hras else 0
print("tiles=%d (of %d golden)  REAL nwi up to 0x%X  max SDRAM 16-bit word 0x%X (bank cap 0x%X)"
      % (len(hras), len(o0), maxnwi, maxw, BANK_CAP-1))
print("wrote sdram_bank3_real.hex (%d words) objfold_real_addr.hex objfold_real_gold.hex objfold_real_n.vh"
      % len(sdram))
