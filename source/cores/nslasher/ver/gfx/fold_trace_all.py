#!/usr/bin/env python3
# ============================================================================
# fold_trace_all.py  --  FULL-RANGE obj0 BANDWIDTH-FOLD address trace.
#
# Traces EVERY sprite tile code (0 .. 0x9FFF) through the REAL fold path and
# diffs it against the ROM-derived golden decode.  Replaces fold_repro.py,
# which only checked the 45 "used" golden codes (gfx3_spr.hex) -- the exact
# anti-pattern that hid the bug.
#
# Pipeline (each stage = exact copy of the named source):
#   GOLDEN  : obj_fetch(g3, hra) from down_pass.py  (ROM-only, ANY code)
#   FOLD    : real ROMs
#             -> real nslashers_FOLD.mra byte order (interleave/pad/spread)
#             -> real jtnslasher_dwnld.v post_addr (BA3 branch)
#             -> real jtnslasher_sdram.v FSM (obj0_nwi, 2-read, assemble,
#                plane4 = o0_p4word[15:8]  <-- the FIXED high-lane read)
#
# Ground truth (HW): only the ~45 kick/portrait codes render correctly; walk /
# jump / enemy codes are garbled.  A correct model MUST reproduce that split.
# ============================================================================
import os, sys
d = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", r"/path/to/nightslashers/mame-dump/roms/nslashers")
rd = lambda f: open(os.path.join(ROM, f), 'rb').read()

NCODES = 0xA000           # planes region [0,0x500000) bytes / 128 B per code
HRA_MAX = NCODES * 32     # 0..0x13FFFF

# ===========================================================================
# GOLDEN: ROM-assembled buffer g3 + obj_fetch (down_pass.py, lines 120-156).
# This is the render-format 40-bit word the FSM must reproduce for ANY code,
# computed directly from the ROMs (independent of the fold/download).
# ===========================================================================
def l16(reg, off, data):
    for i, b in enumerate(data): reg[off+i*2] = b
def l32(reg, off, data):
    for i, b in enumerate(data): reg[off+i*4] = b

g3 = bytearray(0xa00000)
l16(g3, 1,        rd("mbh-02.14c")); l16(g3, 0,        rd("mbh-04.16c"))   # sprites1a [0,0x400000)
l16(g3, 0x400001, rd("mbh-03.15c")); l16(g3, 0x400000, rd("mbh-05.17c"))   # sprites1b [0x400000,0x500000)
l32(g3, 0x500000, rd("mbh-06.18c")); l32(g3, 0x900000, rd("mbh-07.19c"))   # plane4    [0x500000,0xa00000)

def golden_fetch(hra):
    """Render-format 40-bit obj0 word for engine addr hra, straight from ROMs."""
    code = hra >> 5; rowf = (hra >> 1) & 0xf; half = hra & 1
    nwi = code*32 + rowf + (0 if half else 16)
    na = nwi*4
    b0, b1, b2, b3 = g3[na], g3[na+1], g3[na+2], g3[na+3]
    word = b1 | (b3 << 8) | (b0 << 16) | (b2 << 24)        # planes 0-3 = {b2,b0,b3,b1}
    word |= g3[na + 0x500000] << 32                         # plane 4
    return word

# --- INDEPENDENT native pixel-decode golden (reshuffle_spr.py semantics) ---
# Decodes the true MAME planar bit layout pixel-by-pixel (decode_tile), then
# re-packs the half-row (tileword) EXACTLY as reshuffle_spr.py does. Does NOT
# share the obj_fetch byte-permute, so agreement with golden_fetch is a real
# cross-check that golden_fetch is the true decode for ALL codes, not just the
# 45 validated ones.  (decode the full tile once; cache per code.)
_XO = [64*8 + i for i in range(8)] + [i for i in range(8)]
_YO = [i*32 for i in range(16)]
_PO5 = [(0xa00000 // 2) * 8, 16, 0, 24, 8]
_tile_cache = {}
def _decode_tile(code):
    base = code * (128*8)
    px = [[0]*16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            v = 0
            for p in range(5):
                bit = base + _PO5[p] + _YO[y] + _XO[x]
                v |= ((g3[bit >> 3] >> (7 - (bit & 7))) & 1) << (5-1-p)
            px[y][x] = v
    return px
def native_fetch(hra):
    code = hra >> 5; rowf = (hra >> 1) & 0xf; half = hra & 1
    px = _tile_cache.get(code)
    if px is None:
        px = _decode_tile(code); _tile_cache[code] = px
    val = 0
    for i in range(8):
        v = px[rowf][half*8 + i]
        for p in range(5):
            if (v >> p) & 1:
                val |= (1 << (7 - i)) << (8*p)
    return val

# ===========================================================================
# FOLD STEP 1: assemble the REAL .mra BA3 stream (16-bit words within BA3).
# Layout taken VERBATIM from cores/nslasher/fold-wip/nslashers_FOLD.mra:
#   sprites1a @0x000000 : interleave(mbh-02 map01->lo, mbh-04 map10->hi)   len 0x400000
#   sprites1b @0x400000 : interleave(mbh-03 map01->lo, mbh-05 map10->hi)   len 0x100000 real
#   FF pad    @0x500000 : <part repeat="0x300000"> FF</part>               len 0x300000
#   obj0hi6   @0x800000 : interleave(mbh-06 map10) SPREAD {00,b}           1MB->2MB
#   obj0hi7   @0xC00000 : interleave(mbh-07 map10) SPREAD {00,b}           0.25MB->0.5MB
# (all offsets BA3-relative = mra addr - JTFRAME_BA3_START=0x710000.)
# ===========================================================================
def interleave_lohi(part_lo, part_hi):
    n = min(len(part_lo), len(part_hi))
    out = bytearray(2*n)
    for i in range(n):
        out[2*i]   = part_lo[i]      # map="01" -> LOW byte (even addr)
        out[2*i+1] = part_hi[i]      # map="10" -> HIGH byte (odd addr)
    return bytes(out)

def spread_hi(part):
    """single-part map=10: each input byte -> 16-bit word {byte,00} = [00,b0,00,b1,...]."""
    out = bytearray(2*len(part))
    for i, b in enumerate(part):
        out[2*i]   = 0x00            # low lane unused
        out[2*i+1] = b               # HIGH lane = the spread plane4 byte
    return bytes(out)

sprites1a = interleave_lohi(rd("mbh-02.14c"), rd("mbh-04.16c"))   # 0x400000
sprites1b = interleave_lohi(rd("mbh-03.15c"), rd("mbh-05.17c"))   # 0x100000
obj0hi6   = spread_hi(rd("mbh-06.18c"))                           # 0x200000
obj0hi7   = spread_hi(rd("mbh-07.19c"))                           # 0x080000

# BA3-relative byte offsets (from the .mra explicit START list)
SPR1A = 0x710000 - 0x710000   # 0x000000
SPR1B = 0xB10000 - 0x710000   # 0x400000
SPR1C = 0xF10000 - 0x710000   # 0x800000  (after 0x300000 FF pad)
SPR1D = 0x1110000 - 0x710000  # 0xC00000
END   = 0x1190000 - 0x710000  # 0xA80000

BA3 = bytearray(b'\x00' * END)
BA3[SPR1A:SPR1A+len(sprites1a)] = sprites1a
BA3[SPR1B:SPR1B+len(sprites1b)] = sprites1b
for i in range(SPR1B+len(sprites1b), SPR1C): BA3[i] = 0xFF    # the explicit 0x300000 FF pad
BA3[SPR1C:SPR1C+len(obj0hi6)] = obj0hi6
BA3[SPR1D:SPR1D+len(obj0hi7)] = obj0hi7

NWORDS_BA3 = len(BA3) // 2
def ba3_word(w):
    return BA3[2*w] | (BA3[2*w+1] << 8)        # lo=even byte, hi=odd byte

# ===========================================================================
# FOLD STEP 2: real download post_addr (jtnslasher_dwnld.v BA3 branch).
#   planes  (w <  P4BASE): post = {w[21:1], 1'b0, w[0]}   -> insert 0 at bit1
#   plane4  (w >= P4BASE): nwi = w - P4BASE ; post = {nwi, 2'b10} = 4*nwi+2
#   P4BASE = 0x40_0000 (16-bit words) = BA3 byte 0x800000 = SPR1C start. (verified)
# prog_addr/post_addr are 16-bit-WORD indices; byte LANE preserved.
# ===========================================================================
P4BASE = 0x40_0000
assert P4BASE == SPR1C // 2, "P4BASE must equal SPR1C(byte)/2"

def post_addr_word(w):
    if w < P4BASE:
        return ((w >> 1) << 2) | (w & 1)        # {w[21:1],0,w[0]}
    else:
        nwi = w - P4BASE
        return 4*nwi + 2                          # {nwi,2'b10}

# Build the SDRAM image (16-bit words) exactly as the download writes it.
# We materialise it as a flat array sized to the largest post_addr reached.
maxpost = 0
for w in range(NWORDS_BA3):
    p = post_addr_word(w)
    if p > maxpost: maxpost = p
SDRAM16 = bytearray((maxpost + 4) * 2)            # 16-bit words, default 0
for w in range(NWORDS_BA3):
    p = post_addr_word(w)
    val = ba3_word(w)
    SDRAM16[2*p]   = val & 0xff
    SDRAM16[2*p+1] = (val >> 8) & 0xff
NSD16 = len(SDRAM16) // 2
def sdram16(pw):
    if pw < 0 or pw >= NSD16: return 0
    return SDRAM16[2*pw] | (SDRAM16[2*pw+1] << 8)

# ===========================================================================
# FOLD STEP 3: real FSM (jtnslasher_sdram.v).
#   obj0_nwi = { addr[20:5], ~addr[0], addr[4:1] }          (addr = hra)
#   planes 32b word @ obj0_addr={nwi,1'b0}=nwi*2 -> 16b words [4nwi, 4nwi+1]
#   plane4 32b word @ obj0_addr={nwi,1'b1}=nwi*2+1 -> 16b words [4nwi+2, 4nwi+3]
#   assemble: { o0_p4word[15:8], plane_permute(hwswap16(o0_planes)) }
#     o0_planes = {sdram16[4nwi+1], sdram16[4nwi]}  (hi||lo of the 32b word)
#     o0_p4word = {sdram16[4nwi+3], sdram16[4nwi+2]}; FSM uses [15:8] = HIGH
#                 byte of the LOW 16b word (4nwi+2)  <-- the spread plane4 byte
# ===========================================================================
def obj0_nwi(hra):
    code = (hra >> 5) & 0xFFFF       # addr[20:5]
    half = hra & 1                   # addr[0]
    rowf = (hra >> 1) & 0xF          # addr[4:1]
    return (code << 5) | ((half ^ 1) << 4) | rowf

def plane_permute(dw):
    d31_24=(dw>>24)&0xff; d23_16=(dw>>16)&0xff; d15_8=(dw>>8)&0xff; d7_0=dw&0xff
    return (d23_16<<24)|(d7_0<<16)|(d31_24<<8)|d15_8
def hwswap16(dw):
    d31_24=(dw>>24)&0xff; d23_16=(dw>>16)&0xff; d15_8=(dw>>8)&0xff; d7_0=dw&0xff
    return (d23_16<<24)|(d31_24<<16)|(d7_0<<8)|d15_8

def fold_fetch(hra):
    nwi = obj0_nwi(hra)
    lo16 = sdram16(4*nwi + 0)
    hi16 = sdram16(4*nwi + 1)
    planes = lo16 | (hi16 << 16)
    p4word = sdram16(4*nwi + 2)                  # low 16b of the plane4 32b word
    p4byte = (p4word >> 8) & 0xff                # FSM o0_p4word[15:8] (HIGH lane = spread byte)
    planes_render = plane_permute(hwswap16(planes))
    return (p4byte << 32) | planes_render

# ===========================================================================
# STEP 4: compare fold vs golden over the FULL code range, characterize.
# ===========================================================================
if __name__ == "__main__":
    print("=== fold_trace_all : FULL-RANGE obj0 fold trace ===")
    print("BA3 image: %d bytes (%.2f MB) ; SPR1A=%#x SPR1B=%#x SPR1C=%#x SPR1D=%#x END=%#x"
          % (len(BA3), len(BA3)/(1<<20), SPR1A, SPR1B, SPR1C, SPR1D, END))
    print("SDRAM16 image: %d 16-bit words (max post_addr=%#x)" % (NSD16, maxpost))
    print("Tracing codes 0..%#x  (%d codes x 32 half-rows = %d fetches)\n"
          % (NCODES-1, NCODES, NCODES*32))

    # Per-code: does EVERY half-row match golden?
    code_ok   = bytearray(NCODES)        # 1 = all 32 half-rows match
    nbad_hr   = 0
    nall_hr   = 0
    first_mism = []
    # also track where the fold READS from vs where golden reads (address rule)
    for code in range(NCODES):
        allok = True
        for rh in range(32):
            hra = (code << 5) | rh
            g = golden_fetch(hra)
            f = fold_fetch(hra)
            nall_hr += 1
            if g != f:
                nbad_hr += 1
                allok = False
                if len(first_mism) < 16:
                    first_mism.append((hra, g, f))
        code_ok[code] = 1 if allok else 0

    ngood_codes = sum(code_ok)
    print("=== RESULT: per-code match over codes 0..%#x ===" % (NCODES-1))
    print("  codes fully correct : %d / %d  (%.2f%%)"
          % (ngood_codes, NCODES, 100.0*ngood_codes/NCODES))
    print("  half-rows correct   : %d / %d  (%.2f%%)"
          % (nall_hr-nbad_hr, nall_hr, 100.0*(nall_hr-nbad_hr)/nall_hr))

    # --- cross-check golden_fetch against the INDEPENDENT native pixel decode ---
    # (proves golden_fetch is the true decode for ALL codes, not just the 45 used)
    nbad_native = 0
    step = 7                                   # sample every 7th code (full sweep is slow but exact)
    for code in range(0, NCODES, step):
        for rh in range(32):
            hra = (code << 5) | rh
            if golden_fetch(hra) != native_fetch(hra):
                nbad_native += 1
    print("  golden_fetch == native pixel-decode (sampled 1/%d codes): %s"
          % (step, "ALL MATCH" if nbad_native == 0 else "%d MISMATCH" % nbad_native))

    # --- sprites1b / FF-pad boundary audit (the layout the prior trace got wrong) ---
    SPR1B_real_end = 0x400000 + len(sprites1b)          # 0x500000
    in_a = in_b = in_pad = 0
    for code in range(NCODES):
        nwi = obj0_nwi((code << 5) | 0)
        p = 4*nwi                                        # planes low 16b SDRAM word
        ba3w = ((p >> 2) << 1) | (p & 1)                 # invert planes post_addr -> BA3 word
        byte = ba3w * 2
        if   byte < 0x400000:        in_a += 1
        elif byte < SPR1B_real_end:  in_b += 1
        else:                        in_pad += 1
    print("  planes region audit  : %d codes->sprites1a, %d->sprites1b(real), %d->FF-pad %s"
          % (in_a, in_b, in_pad, "(BUG!)" if in_pad else "(none -> pad never read, OK)"))

    # Characterize: contiguous spans of good/bad codes.
    print("\n=== code-span map (good[G]/bad[B] runs) ===")
    runs = []
    i = 0
    while i < NCODES:
        v = code_ok[i]; j = i
        while j < NCODES and code_ok[j] == v: j += 1
        runs.append((v, i, j-1))
        i = j
    # print only the first ~40 runs + summary
    for k, (v, a, b) in enumerate(runs[:48]):
        print("  %s codes %#06x..%#06x  (%d codes)" % ("GOOD" if v else "BAD ", a, b, b-a+1))
    if len(runs) > 48:
        print("  ... (%d total runs)" % len(runs))

    # which codes are GOOD -- compare to the golden gfx3_spr.hex used set
    def load_used():
        used = set(); a = 0
        try:
            for l in open(os.path.join(d, "gfx3_spr.hex")):
                l = l.strip()
                if not l: continue
                if l[0] == '@': a = int(l[1:], 16); continue
                used.add(a >> 5); a += 1
        except FileNotFoundError:
            return None
        return used
    used = load_used()
    if used is not None:
        good_codes = set(c for c in range(NCODES) if code_ok[c])
        print("\n=== cross-check vs gfx3_spr.hex (the 45 'used' golden codes) ===")
        print("  used golden codes        : %d (range %#x..%#x)" % (len(used), min(used), max(used)))
        print("  used codes that are GOOD : %d / %d" % (len(used & good_codes), len(used)))
        print("  used codes that are BAD  : %d" % len(used - good_codes))
        extra_good = good_codes - used
        print("  GOOD codes NOT in used set: %d" % len(extra_good))

    print("\n=== first mismatching half-rows (hra, code, rowf, half) ===")
    for hra, g, f in first_mism[:16]:
        print("  hra=%#08x code=%#06x rowf=%2d half=%d  gold=%010x  fold=%010x"
              % (hra, hra>>5, (hra>>1)&0xf, hra&1, g, f))

    # ---- ADDRESS-RULE characterization: for a sample of BAD codes, find which
    #      golden code (if any) the fold actually returns -> the aliasing g(code).
    print("\n=== address-rule probe: what does fold_fetch(code) actually return? ===")
    # Build a reverse index of golden planes-words so we can identify the source.
    # We test the hypothesis: fold_fetch(hra) == golden_fetch(hra) with a shifted nwi.
    sample = [c for c in range(NCODES) if not code_ok[c]][:8]
    for code in sample:
        hra = (code << 5) | 0     # rowf0 half0
        f = fold_fetch(hra)
        g = golden_fetch(hra)
        nwi = obj0_nwi(hra)
        # where does the fold's planes word physically come from in BA3?
        # planes 16b words read = 4*nwi, 4*nwi+1 in SDRAM. Invert post_addr to BA3 word.
        # post_addr(w)= {w[21:1],0,w[0]} for planes => SDRAM word p has bit1==0, and
        # BA3 word w = {p[21:2], p[0]} (drop p[1]).  (only valid when p[1]==0)
        p = 4*nwi
        ba3w = ((p >> 2) << 1) | (p & 1)
        ba3_byte = ba3w * 2
        region = ("sprites1a" if ba3_byte < SPR1B else
                  "sprites1b" if ba3_byte < SPR1C - 0x300000 else
                  "FF-pad"    if ba3_byte < SPR1C else
                  "plane4!"   )
        print("  code=%#06x nwi=%#x planes<-BA3 word %#x (byte %#x = %s)  gold=%010x fold=%010x"
              % (code, nwi, ba3w, ba3_byte, region, g, f))
