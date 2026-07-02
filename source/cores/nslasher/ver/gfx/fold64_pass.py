#!/usr/bin/env python3
# ============================================================================
# obj0 BANDWIDTH FOLD — Python golden proof (sim-verify FIRST; HANDOFF mandate).
#
# PROBLEM: jtnslasher_obj fetches a 40-bit gfx3 word per sprite tile-half-row.
# Today that is SPLIT across two BA3 buses sharing one address:
#     obj0lo (DW32, planes 0-3)  +  obj0hi (DW8, plane 4)
# jtframe_sdram64 uses a FIXED 64-bit (4-beat) burst per access, so:
#   - obj0lo (DW32) costs a full 4-beat burst (uses 32 of 64 fetched bits)
#   - obj0hi (DW8)  costs a full 4-beat burst to fetch ONE byte  (pathological)
# = TWO bursts + TWO row-activations per tile-half-row. Under heavy sprite load
#   BA3 saturates -> slowdown (and, the handoff reports, scramble).
#
# FIX: fold the 40 bits into ONE DW64 bus -> ONE 4-beat burst, ONE activation
#   per tile-half-row (halves obj0 SDRAM occupancy; also removes the obj0hi bus
#   entirely so BA3 has 2 buses instead of 3). Framework supports DW64
#   (mem.go cache_data_aw0 case 64 -> 4-word slot; romrq DOUBLE generalises).
#
# This script PROVES, build-free, that:
#   (A) a single 64-bit-aligned read of the packed image reproduces the golden
#       40-bit obj0 word for EVERY used tile (the fetch logic is correct);
#   (B) the address map is BIJECTIVE (no slot collisions);
#   (C) the packed layout is DOWNLOAD/MRA-feasible (the byte-lane constraint);
#   (D) the BA3 budget (does the doubled planes region still fit the bank?).
#
# Inputs (already emitted by down_pass.py; no ROMs needed):
#   gfx3_spr.hex      golden 40-bit obj0 words, keyed by hra = code*32+rowf*2+half
#   obj0lo_native.hex native planes-0-3 32-bit word,  keyed by nwi
#   obj0hi_native.hex native plane-4 byte,            keyed by nwi
# (The HW per-16-bit-half byteswap `hwswap16` is an orthogonal SDRAM-delivery
#  artifact, layered identically in RTL; this native-order proof is unaffected.)
# ============================================================================
import os, sys
d = os.path.dirname(os.path.abspath(__file__))

def load_hex(name):
    """@addr / value sparse hex -> {addr:int}."""
    out = {}; addr = 0
    for l in open(os.path.join(d, name)):
        l = l.strip()
        if not l: continue
        if l[0] == '@': addr = int(l[1:], 16); continue
        out[addr] = int(l, 16); addr += 1
    return out

o0   = load_hex("gfx3_spr.hex")        # hra -> 40-bit golden
lo_n = load_hex("obj0lo_native.hex")   # nwi -> native 32-bit planes 0-3
hi_n = load_hex("obj0hi_native.hex")   # nwi -> native plane-4 byte

# ---- address remap (identical to jtnslasher_sdram / down_pass) ----
def remap(hra):                        # hra = code*32 + rowf*2 + half  ->  nwi
    code = hra >> 5; rowf = (hra >> 1) & 0xf; half = hra & 1
    return code*32 + rowf + (0 if half else 16)   # = {code, ~half, rowf}

# ---- render-plane permute (native {b0,b1,b2,b3} -> golden {b1,b3,b0,b2}) ----
# Matches down_pass.obj_fetch: word = b1|(b3<<8)|(b0<<16)|(b2<<24).
def permute(n):
    b0 =  n        & 0xff; b1 = (n >> 8) & 0xff
    b2 = (n >> 16) & 0xff; b3 = (n >> 24) & 0xff
    return b1 | (b3 << 8) | (b0 << 16) | (b2 << 24)

# ============================================================================
# (A) FETCH PROOF — pack the 64-bit word, read it ONCE, reconstruct 40 bits.
#   pack64[nwi] = { 24'b0, plane4[7:0], native_planes0-3[31:0] }   (8 bytes)
#   fetch(hra): nwi=remap(hra); w=pack64[nwi];
#               render40 = (permute(w[31:0])) | (w[39:32] << 32)
# ============================================================================
pack64 = {}
for nwi in lo_n:
    pack64[nwi] = (hi_n.get(nwi, 0) << 32) | lo_n[nwi]   # plane4 in byte 4

def fetch64(hra):
    nwi = remap(hra)
    w = pack64[nwi]
    return permute(w & 0xffffffff) | (((w >> 32) & 0xff) << 32)

bad = 0; n = 0
for hra, gold in o0.items():
    n += 1
    if fetch64(hra) != gold:
        bad += 1
        if bad <= 4:
            print("  MISMATCH hra=%#x nwi=%#x  got=%010x  gold=%010x" % (hra, remap(hra), fetch64(hra), gold))
print("(A) single-DW64-read fetch == golden 40-bit obj0 word : %s  (%d/%d tiles)"
      % ("BIT-EXACT" if bad == 0 else "%d BAD" % bad, n - bad, n))

# ============================================================================
# (B) BIJECTIVITY — every used hra maps to a distinct nwi slot; no two tiles
#     collide in the packed image.
# ============================================================================
seen = {}; collide = 0
for hra in o0:
    nwi = remap(hra)
    if nwi in seen and seen[nwi] != hra:
        collide += 1
        if collide <= 4: print("  COLLISION nwi=%#x from hra=%#x and %#x" % (nwi, seen[nwi], hra))
    seen[nwi] = hra
print("(B) hra->nwi slot map injective (no collisions)        : %s  (%d distinct slots)"
      % ("OK" if collide == 0 else "%d COLLISIONS" % collide, len(seen)))

# ============================================================================
# (C) DOWNLOAD / MRA FEASIBILITY — the byte-lane constraint.
#   jtframe download: post_addr remaps the 16-bit-WORD address only; the byte
#   LANE (hi/lo of a 16-bit SDRAM word) is fixed by the source byte's parity.
#   A 64-bit slot nwi spans 16-bit words [nwi*4 .. nwi*4+3]:
#       word nwi*4+0 = {plane1, plane0}     <- native planes word low half
#       word nwi*4+1 = {plane3, plane2}     <- native planes word high half
#       word nwi*4+2 = { ----- , plane4}    <- plane-4 byte
#       word nwi*4+3 = unused (pad)
#   planes-0-3: native word nwi occupies source 16-bit words (nwi*2, nwi*2+1).
#     post_addr  W -> {W[hi:1], 1'b0, W[0]}  (insert a 0 at bit1) lands them at
#     (nwi*4, nwi*4+1) with byte LANES PRESERVED  -> feasible by word-remap.
#   plane-4: if delivered DENSE (1 byte/addr) two adjacent P4 bytes share one
#     source 16-bit word but must go to DIFFERENT slots -> a single post_addr
#     cannot split them (the byte-lane constraint).  RESOLUTION: the MRA must
#     deliver plane-4 SPREAD (1 byte per 16-bit source word, other lane unused),
#     so each P4[nwi] owns a source word -> post_addr -> slot word nwi*4+2.
#   Verify the planes word-remap is a bijection over the used source words.
# ============================================================================
def planes_postaddr(W):                 # native planes src word -> packed slot word
    return ((W & ~1) << 1) | (W & 1)    # insert 0 at bit1: {W[hi:1],0,W[0]}
src_words = set()
img = {}
ok_lane = True
for nwi in lo_n:
    for half in (0, 1):                 # the two 16-bit halves of the native planes word
        W = nwi*2 + half
        dst = planes_postaddr(W)
        if dst in img and img[dst] != ('P', W):
            ok_lane = False
        img[dst] = ('P', W)
        assert dst == nwi*4 + half, "planes remap target mismatch"
    # plane-4 spread: its own source word -> slot word nwi*4+2
    dst4 = nwi*4 + 2
    if dst4 in img: ok_lane = False
    img[dst4] = ('4', nwi)
print("(C) download/MRA placement bijective (spread plane-4)   : %s  (%d packed 16b words used)"
      % ("OK" if ok_lane else "LANE CONFLICT", len(img)))

# ============================================================================
# (D) BA3 BUDGET — does the folded layout fit the bank?
#   addressable extent must cover the max nwi the engine can request. The
#   current obj0lo slot address is [22:2] (21 bits) -> nwi < 2^21 -> the planes
#   region is sized for 2^21 32-bit words = 8 MB. DW64 = 2^21 * 8 B = 16 MB.
#   Bank = 8 MB (default) or 16 MB (JTFRAME_SDRAM_LARGE).  obj1 (gfx4) = 1 MB.
# ============================================================================
NWI_ADDR_BITS = 21                      # obj0lo slot addr [22:2]
addr_extent  = 1 << NWI_ADDR_BITS
used_max_nwi = max(lo_n) if lo_n else 0
packed_obj0_MB   = addr_extent * 8 / (1024*1024)
current_obj0_MB  = addr_extent * 4 / (1024*1024) + 2     # planes 8MB + plane4 2MB
obj1_MB = 1
print("(D) BA3 budget:")
print("    used max nwi          = %#x  (%.2f MB of the %d-bit addr extent actually populated)"
      % (used_max_nwi, used_max_nwi*8/(1024*1024), NWI_ADDR_BITS))
print("    obj0 today (lo+hi)    = %.0f MB ;  obj0 folded (DW64) = %.0f MB ;  obj1 = %d MB"
      % (current_obj0_MB, packed_obj0_MB, obj1_MB))
print("    BA3 today  = %.0f MB  ->  BA3 folded = %.0f MB (obj0) + %d MB (obj1) = %.0f MB"
      % (current_obj0_MB+obj1_MB, packed_obj0_MB, obj1_MB, packed_obj0_MB+obj1_MB))
for bank in (8, 16):
    fits_full = packed_obj0_MB + obj1_MB <= bank
    fits_relo = packed_obj0_MB <= bank      # obj1 moved out of BA3
    print("    bank=%2d MB : obj0+obj1 in BA3 %s ; obj0-only (obj1 relocated) %s"
          % (bank, "FITS" if fits_full else "OVERFLOWS", "FITS" if fits_relo else "OVERFLOWS"))

# sizing by USED extent only (if the addr_width were trimmed to the real tiles):
trim_bits = (used_max_nwi).bit_length()
trim_MB = (1 << trim_bits) * 8 / (1024*1024)
print("    if addr_width trimmed to used tiles (%d-bit nwi): obj0 folded = %.1f MB"
      % (trim_bits, trim_MB))

print()
allgood = (bad == 0 and collide == 0 and ok_lane)
print("RESULT:", "FOLD VERIFIED (fetch + bijection + lane-feasible)" if allgood else "*** FAILED ***")
sys.exit(0 if allgood else 1)
