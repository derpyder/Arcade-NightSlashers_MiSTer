#!/usr/bin/env python3
# Emit the preload + test-vectors for tb_objfold_combined.v — the DECISIVE seam sim that drives the
# REAL obj0 2-read FSM (jtnslasher_sdram) through the REAL cache + SDRAM + OKLATCH=1 path
# (jtframe_rom_1slot DW32 DOUBLE + jtframe_sdram64 + mt48lc16m16a2), exactly as the generated
# jtnslasher_game_sdram wires it on hardware.
#
# Faithfulness vs. capacity: the real obj0 image spans BA3 (16 MB, JTFRAME_SDRAM_LARGE) so its native
# nwi values reach 0x137dff -> SDRAM 16-bit word 0x4DF7FF, which OVERFLOWS one mt48lc16m16a2 bank
# (4M x 16 = 0x3FFFFF). The OKLATCH stale-ok seam is per-tile-LOCAL (planes -> plane4 within ONE
# 8-byte slot), independent of the absolute address, so we COMPACT-REMAP every golden tile to a dense
# sequential nwi (0,1,2,...) and drive the FSM with the engine address that the FSM's fixed nwi
# permutation maps to that compact nwi. The cache/SDRAM/OKLATCH path is byte-for-byte the real one;
# only the absolute slot address is compacted. Every one of the 1440 golden tiles is tested.
#
# FSM nwi permutation (jtnslasher_sdram.v):  nwi = { a[20:5], ~a[0], a[4:1] }
#   so for a target compact nwi N:  a[20:5]=N[20:5] ; a[0]=~N[4] ; a[4:1]=N[3:0]   (other a bits 0)
# obj0_addr (32-bit-word index) planes={nwi,0}, plane4={nwi,1}.
# slot0_addr={obj0_addr,1'b0}; romrq DW32 -> sdram_addr (16-bit words) = {slot0_addr[hi:1],1'b0}.
#   planes 32-bit word -> SDRAM 16-bit words  nwi*4+0 (low), nwi*4+1 (high)
#   plane4 32-bit word -> SDRAM 16-bit words  nwi*4+2 (low), nwi*4+3 (high)
# Each 32-bit word is stored low-half-first (SDRAM[2i]=w&0xFFFF, SDRAM[2i+1]=w>>16) — matches the
# verified gen_preload.py convention and tb_objread's AAAA,1111 -> 0x1111AAAA.

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

def remap_native_nwi(hra):                # hra -> the game's NATIVE nwi (used to index lo_n/hi_n)
    code = hra >> 5; rowf = (hra >> 1) & 0xf; half = hra & 1
    return code*32 + rowf + (0 if half else 16)

def hwswap16(x):                          # byte-swap each 16-bit half (HW SDRAM delivery order)
    return ((x >> 8) & 0x00FF00FF) | ((x << 8) & 0xFF00FF00)

def addr_for_nwi(N):                       # invert the FSM permutation: engine addr that yields nwi N
    a  = ((N >> 5) & 0xFFFF) << 5          # a[20:5] = N[20:5]
    a |= (0 if ((N >> 4) & 1) else 1)      # a[0]    = ~N[4]
    a |= (N & 0xF) << 1                    # a[4:1]  = N[3:0]
    return a

hras = sorted(o0)                          # all 1440 golden tiles, deterministic order
assert len(hras) <= 0x7FF, "compact nwi must fit a[20:5] field"

sdram = {}                                 # 16-bit SDRAM word address -> 16-bit value (sparse)
tv_addr = []                               # engine obj0_rom_addr per tile (drives the FSM)
tv_gold = []                               # golden 40-bit render word per tile

for cN, hra in enumerate(hras):            # cN = compact nwi
    nat = remap_native_nwi(hra)
    planes = hwswap16(lo_n.get(nat, 0) & 0xFFFFFFFF)   # HW-order planes word
    p4word = (hi_n.get(nat, 0) & 0xFF) << 8            # plane4 in HIGH byte of word base+2 (.mra map="10"); FSM reads o0_p4word[15:8]
    base = cN * 4                                       # SDRAM 16-bit word base for this slot
    sdram[base+0] = planes & 0xFFFF
    sdram[base+1] = (planes >> 16) & 0xFFFF
    sdram[base+2] = p4word & 0xFFFF
    sdram[base+3] = (p4word >> 16) & 0xFFFF
    tv_addr.append(addr_for_nwi(cN))
    tv_gold.append(o0[hra])

# sdram_bank3.hex — flat 16-bit-per-word image the mt48lc16m16a2 model $readmemh's into Bank3.
# Written as a sparse @-addressed hex (compact, contiguous runs).
with open(os.path.join(D, "sdram_bank3.hex"), "w") as f:
    prev = None
    for a in sorted(sdram):
        if a != prev:
            f.write("@%X\n" % a)
        f.write("%04X\n" % sdram[a])
        prev = a + 1

with open(os.path.join(D, "objfold_tv_addr.hex"), "w") as f:
    for a in tv_addr: f.write("%06x\n" % a)
with open(os.path.join(D, "objfold_tv_gold.hex"), "w") as f:
    for g in tv_gold: f.write("%010x\n" % g)
with open(os.path.join(D, "objfold_combined_n.vh"), "w") as f:
    f.write("`define OBJFOLD_N %d\n" % len(hras))

maxw = max(sdram) if sdram else 0
print("tiles=%d  compact nwi 0..%d  max SDRAM 16-bit word 0x%X (bank cap 0x3FFFFF)"
      % (len(hras), len(hras)-1, maxw))
print("wrote sdram_bank3.hex (%d words) objfold_tv_addr.hex objfold_tv_gold.hex objfold_combined_n.vh"
      % len(sdram))
