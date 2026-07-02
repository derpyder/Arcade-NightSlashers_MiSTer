#!/usr/bin/env python3
# verify_fold_dense.py — VERIFY the FOLD-DENSE obj0 (gfx3 5bpp) pixel pipeline is byte-exact vs MAME.
#
# Adapted from verify_nonfold.py for the DENSE-PACK FOLD BA3 layout (single 32MB SDRAM, 8MB BA3):
#   planes word @ BA3-rel byte 4*nwi  (UNCHANGED from non-fold; the proven transform is preserved)
#   plane4 byte @ BA3-rel byte P4_BASE+nwi   (DENSE; P4_BASE=0x500000, was 0x800000 in non-fold)
#   gfx4/obj1   @ BA3-rel byte GFX4_REL=0x640000 (was 0xA00000; pulled in so 8MB BA3 fits)
# The plane BYTES reaching the engine are IDENTICAL to the proven non-fold path — only the BA3 image
# model is re-pointed (planes word @ slot_planes(nwi), plane4 byte @ slot_p4(nwi)). MAME golden UNCHANGED.
#
# The dense BA3 image is what the dwnll post-pass produces. We build it explicitly here (planes from the
# native source @ dense planes base; plane4 from the native source @ dense plane4 base) and prove the
# RTL transform reads it byte-exact vs the MAME spritelayout_5bpp golden.
#
# Self-contained: reads raw ROMs + the PLAIN .mra only. No external golden hex needed.
import os, re, sys, itertools, struct, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
# Path roots — try a couple of layouts so this runs from Bash (/d/...) or WSL (/mnt/d/...)
def first_existing(*cands):
    for c in cands:
        if os.path.exists(c): return c
    return cands[0]
ROM = first_existing(os.environ.get("ROMDIR",""), "/path/to/nightslashers/roms",
                      "/d/deck/fpga/nightslashers/roms", "/path/to/nightslashers/roms")
MRA = first_existing(
    "/path/to/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra",
    "/d/deck/fpga/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra",
    "/path/to/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra")
romfile = lambda nm: open(os.path.join(ROM, nm), "rb").read()

# ======================================================================================
# (A) MAME GOLDEN — build the 0xa00000 "gfx3" region from raw ROMs, then spritelayout_5bpp.
#     ROM_LOAD16_BYTE odd@+1 even@+0 (stride 2); ROM_LOAD32_BYTE stride 4.
# ======================================================================================
def build_gfx3_region():
    reg = bytearray(0xa00000)
    def load16(nm, base):                      # ROM_LOAD16_BYTE: one byte every 2 (base picks odd/even)
        data = romfile(nm)
        for i, b in enumerate(data):
            reg[base + 2*i] = b
    def load32(nm, base):                      # ROM_LOAD32_BYTE: one byte every 4
        data = romfile(nm)
        for i, b in enumerate(data):
            reg[base + 4*i] = b
    load16("mbh-02.14c", 0x000001)
    load16("mbh-04.16c", 0x000000)
    load16("mbh-03.15c", 0x400001)
    load16("mbh-05.17c", 0x400000)
    load32("mbh-06.18c", 0x500000)
    load32("mbh-07.19c", 0x900000)
    return bytes(reg)

GFX3 = build_gfx3_region()
# RAW-ROM sanity: prove no intermediate. reg[1]=mbh-02[0], reg[0]=mbh-04[0], reg[0x500000]=mbh-06[0]
assert GFX3[1] == romfile("mbh-02.14c")[0], "gfx3 region sanity (mbh-02) FAILED"
assert GFX3[0] == romfile("mbh-04.16c")[0], "gfx3 region sanity (mbh-04) FAILED"
assert GFX3[0x500000] == romfile("mbh-06.18c")[0], "gfx3 region sanity (mbh-06) FAILED"

RGN_HALF_BIT = (0xa00000 * 8) // 2            # RGN_FRAC(1,2) in BITS = byte 0x500000 * 8
PLANEOFFSET  = [RGN_HALF_BIT, 16, 0, 24, 8]   # MAME spritelayout_5bpp planeoffset (plane0=MSB pen bit)
XOFFSET      = [64*8+0,64*8+1,64*8+2,64*8+3,64*8+4,64*8+5,64*8+6,64*8+7, 0,1,2,3,4,5,6,7]
YOFFSET      = [r*32 for r in range(16)]
CHARINC      = 128*8                           # bits per tile

def gbit(bitaddr):                             # read one bit from the gfx3 region (MAME bit order: MSB first within byte)
    byte = bitaddr >> 3
    return (GFX3[byte] >> (7 - (bitaddr & 7))) & 1

def golden_tile(code):
    """Return 16x16 grid of 5bpp pens for tile `code`, decoded by MAME's spritelayout_5bpp."""
    base = code * CHARINC
    grid = [[0]*16 for _ in range(16)]
    nplanes = 5
    for ry in range(16):
        for rx in range(16):
            v = 0
            for p in range(nplanes):
                bit = gbit(base + YOFFSET[ry] + XOFFSET[rx] + PLANEOFFSET[p])
                v |= bit << (nplanes - 1 - p)   # MAME: plane index p -> pen bit (planes-1-p); plane0=MSB
            grid[ry][rx] = v
    return grid

# ======================================================================================
# (B) AUTHORITATIVE big-endian mra2rom interleave  (port of jtframe mra2rom.go interleave2rom).
#     Emits HIGH-output-byte FIRST (big-endian).
# ======================================================================================
def interleave2rom(width_bits, parts):
    width = width_bits >> 3
    fingers = [[data, mapstr, max(int(c) for c in mapstr), 0] for data, mapstr in parts]
    sel = [0]*width
    for j in range(width):
        for k in range(len(fingers)):
            if fingers[k][1][j] != '0':
                sel[j] = k; break
    out = bytearray()
    while True:
        for j in range(width-1, -1, -1):                  # HIGH byte first
            f = fingers[sel[j]]
            i = f[3] + ((ord(f[1][j]) - ord('1')) & 0xff)
            out.append(f[0][i] if i < len(f[0]) else 0)
        brk = False
        for f in fingers:
            f[3] += f[2]
            if f[3] >= len(f[0]): brk = True
        if brk: break
    return bytes(out)

def build_blob():
    body = re.search(r'<rom index="0"[^>]*>(.*?)</rom>', open(MRA).read(), re.S).group(1)
    blob = bytearray()
    TOK = re.compile(r'<interleave output="(\d+)">(.*?)</interleave>'
                     r'|<part name="([^"]+)"\s*crc="[^"]*"\s*/>'
                     r'|<part repeat="([^"]+)">\s*([0-9A-Fa-f]+)\s*</part>', re.S)
    for t in TOK.finditer(body):
        if t.group(1):
            parts = [(romfile(nm), mp) for nm, mp in
                     re.findall(r'<part name="([^"]+)"[^>]*map="([^"]*)"', t.group(2))]
            blob += interleave2rom(int(t.group(1)), parts)
        elif t.group(3):
            blob += romfile(t.group(3))
        else:
            blob += bytes([int(t.group(5),16)]) * int(t.group(4),16)
    return bytes(blob)

BLOB = build_blob()
print("authoritative blob = 0x%X bytes (expect 0x1110000)" % len(BLOB))
assert len(BLOB) == 0x1110000, "blob length mismatch"

# ======================================================================================
# (C) Carve the PLAIN-MRA BA3 (source planes + source plane4) and BUILD the DENSE-PACK BA3 image.
#     PLAIN .mra BA3 (the proven source bytes, BA3_START=0x610000):
#        planes0-3  @ rel 0x000000  (DW32 word at byte 4*nwi)
#        plane4      @ rel 0x800000  (dense byte stream at 0x800000+nwi)
#     DENSE-PACK BA3 (what the dwnll post-pass produces, single 32MB SDRAM, 8MB BA3):
#        PLANES_BASE = 0x000000   planes word @ byte 4*nwi          (UNCHANGED)
#        P4_BASE     = 0x500000   plane4 byte @ byte P4_BASE+nwi    (DENSE; was 0x800000)
#        GFX4_REL    = 0x640000   gfx4/obj1 1 MB                    (was 0xA00000)
#     The DENSE planes bytes are bit-identical to the source planes bytes (same 4*nwi word); the DENSE
#     plane4 byte is bit-identical to the source plane4 byte (same dense nwi stream), only re-based.
# ======================================================================================
BA3_START      = 0x610000
SRC_PLANES_OFF = 0x000000
SRC_P4_OFF     = 0x800000      # plain-MRA source plane4 base
PLANES_BASE    = 0x000000      # dense planes base (BA3-rel byte)
P4_BASE        = 0x500000      # dense plane4 base (BA3-rel byte)  -> SPR1C abs = 0xB10000
GFX4_REL       = 0x640000      # dense gfx4/obj1 base (BA3-rel byte) -> GFX4_START abs = 0xC50000
BA3_SIZE       = 0x800000      # 8 MB bank (no SDRAM_LARGE)
SRC = BLOB[BA3_START:]

# sanity: confirm the plain-MRA source region map
assert all(b == 0xFF for b in SRC[0x500000:0x800000]),    "SRC 0x500000..0x7FFFFF expected all-FF pad"
print("plain-MRA source map OK: planes0-3 @0x000000, FF pad 0x500000-0x7FFFFF, plane4 @0x800000, gfx4 @0xA00000")

# nwi range physically present. The plain-MRA planes region spans [0,0x500000) = 0x140000 32-bit words,
# and the dense plane4 stream spans [0x800000,0x940000) = 0x140000 bytes -> nwi in [0,0x140000).
# (obj0lo_native.hex's max NON-ZERO nwi is 0x137def, but the physical regions are larger; size the copy by
#  the physical region so the stride-7 sweep — which reaches nwi 0x13ffbf — reads real data, not FF pad.)
N_NWI   = 0x140000            # planes region 0x140000*4 = 0x500000 bytes; plane4 0x140000 bytes
MAX_NWI = N_NWI - 1

# ---- BUILD the dense BA3 image (the dwnll post-pass output) ----
BA3 = bytearray(b'\xFF' * BA3_SIZE)
# planes: copy each nwi's 4-byte planes word from source 4*nwi -> dense 4*nwi (identity copy)
BA3[PLANES_BASE:PLANES_BASE + 4*N_NWI] = SRC[SRC_PLANES_OFF:SRC_PLANES_OFF + 4*N_NWI]
# plane4: copy the dense byte stream from source 0x800000+nwi -> dense P4_BASE+nwi
BA3[P4_BASE:P4_BASE + N_NWI] = SRC[SRC_P4_OFF:SRC_P4_OFF + N_NWI]
# gfx4/obj1: copy 1 MB from source 0xA00000 -> dense GFX4_REL (not used by gate-A obj0 check; kept exact)
BA3[GFX4_REL:GFX4_REL + 0x100000] = SRC[0xA00000:0xA00000 + 0x100000]

# overflow guard: the dense pack must fit the 8 MB bank
assert GFX4_REL + 0x100000 <= BA3_SIZE, "DENSE BA3 OVERFLOWS 8 MB"
print("DENSE BA3 built: planes@0x%X (4B/nwi), plane4@0x%X (1B/nwi), gfx4@0x%X ; used end 0x%X (<=0x%X)"
      % (PLANES_BASE, P4_BASE, GFX4_REL, GFX4_REL + 0x100000, BA3_SIZE))

def obj0lo_word_LE(nwi):      # fabric reads 32b little-endian: {ba3[4n+3],ba3[4n+2],ba3[4n+1],ba3[4n]}
    b = BA3[PLANES_BASE + 4*nwi : PLANES_BASE + 4*nwi + 4]
    return b[0] | (b[1]<<8) | (b[2]<<16) | (b[3]<<24)
def obj0lo_word_BE(nwi):
    b = BA3[PLANES_BASE + 4*nwi : PLANES_BASE + 4*nwi + 4]
    return (b[0]<<24) | (b[1]<<16) | (b[2]<<8) | b[3]
P4_WORD_BASE = P4_BASE >> 2   # 32-bit-word base of the dense plane4 region = 0x140000

def p4word_LE(word):          # fabric reads the plane4 32-bit word little-endian (4 dense plane4 bytes)
    b = BA3[4*word : 4*word + 4]
    return b[0] | (b[1]<<8) | (b[2]<<16) | (b[3]<<24)

def obj0hi_byte(nwi):
    # EXACT FSM model: the obj0 2-read FSM's 2nd read targets the dense plane4 32-bit word at
    #   obj0_addr = P4_WORD_BASE + (nwi>>2).  The returned 32-bit word holds 4 dense plane4 bytes, one
    # per nwi[1:0] lane (the little-endian byte assembly == the BA3 dense byte stream). plane4 needs NO
    # hwswap (the proven non-fold DW8 path read the dense byte directly): the adapter selects the RAW lane
    #   plane4 = o0_p4word[8*nwi[1:0] +: 8]  == BA3[P4_BASE+nwi].
    word  = P4_WORD_BASE + (nwi >> 2)
    p4w   = p4word_LE(word)                     # little-endian = BA3 dense bytes, lane L = byte at 4*word+L
    lane  = nwi & 3
    return (p4w >> (8*lane)) & 0xff

# ======================================================================================
# (D) AS-BUILT RTL transform + obj-engine pixel extraction.
# ======================================================================================
def hwswap16(x):              # {d[23:16],d[31:24],d[7:0],d[15:8]}
    return (((x>>16)&0xff)<<24) | (((x>>24)&0xff)<<16) | ((x&0xff)<<8) | ((x>>8)&0xff)
def plane_permute(x):         # native {b3,b2,b1,b0} -> render {b2,b0,b3,b1}
    return (((x>>16)&0xff)<<24) | ((x&0xff)<<16) | (((x>>24)&0xff)<<8) | ((x>>8)&0xff)

def nwi_asbuilt(code, row, half):    # {code, ~half, row}
    return (code<<5) | ((0 if half else 1)<<4) | row

def render_word_asbuilt(code, row, half):
    nwi  = nwi_asbuilt(code, row, half)
    lo   = obj0lo_word_LE(nwi)
    p4   = obj0hi_byte(nwi) & 0xff
    return (p4 << 32) | plane_permute(hwswap16(lo))

def extract_row_from_words(w_half0, w_half1, bpp=5, flip=False):
    """obj engine: draw_pxl[gi] = bit(7-i) of render byte gi. half selects column-group.
       Non-flipped: leftmost pixel i=0 reads bit7. Returns 16 pens left->right."""
    px = [0]*16
    for half, rw in ((0, w_half0), (1, w_half1)):
        for i in range(8):
            v = 0
            for p in range(bpp):
                v |= ((rw >> (8*p + 7 - i)) & 1) << p
            px[half*8 + i] = v
    return px

def asbuilt_tile(code):
    grid = [[0]*16 for _ in range(16)]
    for row in range(16):
        w0 = render_word_asbuilt(code, row, 0)
        w1 = render_word_asbuilt(code, row, 1)
        grid[row] = extract_row_from_words(w0, w1)
    return grid

# ======================================================================================
# (E) Hardcoded golden grids from the independent MAME-golden extraction (cross-check the
#     raw-ROM decode against the human-verified reference).
# ======================================================================================
GOLDEN_HEX = {
0x000d: """
00 00 00 00 00 06 1e 1e 09 09 1e 00 00 00 00 00
00 00 00 00 00 07 1e 1e 1e 1e 1e 00 00 00 00 00
00 00 00 00 00 00 07 1e 1e 1e 1e 00 00 00 00 00
00 00 00 00 00 00 08 1e 1e 1e 07 00 00 00 00 00
00 00 00 00 00 00 00 08 09 08 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00""",
0x000e: """
00 00 00 00 00 00 00 00 00 15 15 16 17 16 16 16
00 00 00 00 00 00 00 00 00 00 15 16 17 17 16 16
00 00 00 00 00 00 00 00 00 00 15 15 16 17 16 15
00 00 00 00 00 00 00 00 00 00 00 15 15 16 15 10
00 00 00 00 00 00 00 00 00 00 00 00 15 15 15 10
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 10
00 00 00 00 00 00 00 00 00 00 00 00 00 00 15 16
00 00 00 00 00 00 00 00 00 00 00 00 00 00 15 15
00 00 00 00 00 00 00 00 00 00 00 00 00 00 15 15
00 00 00 00 00 00 00 00 00 00 00 00 00 00 15 16
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 10
00 00 00 00 00 00 00 00 00 00 00 00 00 00 06 10
00 00 00 00 00 00 00 00 00 00 00 00 00 06 08 07
00 00 00 00 00 00 00 00 00 00 00 00 06 08 09 09
00 00 00 00 00 00 00 00 00 00 00 00 06 07 08 09
00 00 00 00 00 00 00 00 00 00 00 06 06 07 08 08""",
0x000f: """
00 00 00 00 00 00 00 00 00 00 00 06 07 07 07 09
00 00 00 00 00 00 00 00 00 00 00 06 07 07 08 09
00 00 00 00 00 00 00 00 00 00 06 06 07 08 09 08
00 00 00 00 00 00 00 00 00 00 06 07 07 08 0a 08
00 00 00 00 00 00 00 00 00 06 07 07 08 09 0a 09
00 00 00 00 00 00 00 00 00 06 07 08 09 09 0a 09
00 00 00 00 00 00 00 00 06 07 08 07 07 08 0a 0a
00 00 00 00 00 00 00 00 06 07 06 10 06 07 09 0a
00 00 00 00 00 00 00 00 06 06 11 11 10 06 08 09
00 00 00 00 00 00 00 00 06 07 12 12 11 06 07 08
00 00 00 00 00 00 00 00 07 08 09 08 07 06 07 07
00 00 00 00 00 00 00 07 08 09 1f 09 07 06 06 06
00 00 00 00 00 00 1e 07 08 1f 1f 09 00 00 00 00
00 00 00 00 00 00 1e 08 09 1f 1f 08 00 00 00 00
00 00 00 00 00 1e 1e 08 1f 1f 1f 1e 00 00 00 00
00 00 00 00 00 1e 1e 09 1f 1f 09 1e 00 00 00 00""",
}
def parse_grid(s):
    rows = [r for r in s.strip().splitlines() if r.strip()]
    return [[int(x,16) for x in r.split()] for r in rows]

REF_CODES = [0x000d, 0x000e, 0x000f]

# First: does my raw-ROM golden decode match the human-verified reference grids?
print("\n=== (E) raw-ROM MAME decode vs human-verified golden grids ===")
gold_ok = True
for code in REF_CODES:
    mine = golden_tile(code)
    ref  = parse_grid(GOLDEN_HEX[code])
    diff = sum(1 for ry in range(16) for rx in range(16) if mine[ry][rx] != ref[ry][rx])
    print("  code=0x%04x : %s (%d/256 px differ)" % (code, "MATCH" if diff==0 else "MISMATCH", diff))
    if diff: gold_ok = False
assert gold_ok, "raw-ROM golden decode disagrees with the human-verified reference — fix the model first"

# ======================================================================================
# (F) AS-BUILT vs GOLDEN.
# ======================================================================================
print("\n=== (F) AS-BUILT non-fold obj0 pipeline vs MAME golden ===")
total_px = 0; total_bad = 0
per_plane_bad = [0]*5      # mismatch count per pen-bit (plane)
per_code = {}
for code in REF_CODES:
    gold = golden_tile(code)
    ab   = asbuilt_tile(code)
    bad  = 0
    for ry in range(16):
        for rx in range(16):
            total_px += 1
            if gold[ry][rx] != ab[ry][rx]:
                bad += 1; total_bad += 1
                x = gold[ry][rx] ^ ab[ry][rx]
                for p in range(5):
                    if (x>>p)&1: per_plane_bad[p] += 1
    per_code[code] = bad
    print("  code=0x%04x : %s (%d/256 px differ)" % (code, "MATCH" if bad==0 else "MISMATCH", bad))
asbuilt_match_pct = 100.0 * (total_px - total_bad) / total_px
print("  AS-BUILT match = %.2f%% (%d/%d px)" % (asbuilt_match_pct, total_px-total_bad, total_px))
print("  per-plane mismatch (bit p of pen): " +
      " ".join("p%d=%d" % (p, per_plane_bad[p]) for p in range(5)))

# extended coverage sweep (non-blank tiles across the full range)
def tile_nonblank(code):
    g = golden_tile(code)
    return any(g[ry][rx] for ry in range(16) for rx in range(16))
sweep_codes = [c for c in range(0, 0xa000, 7)]     # stride 7 across whole gfx3
sw_total=sw_bad=sw_nz=0
for c in sweep_codes:
    g = golden_tile(c)
    if not any(g[ry][rx] for ry in range(16) for rx in range(16)):
        continue
    sw_nz += 1
    a = asbuilt_tile(c)
    for ry in range(16):
        for rx in range(16):
            sw_total += 1
            if g[ry][rx] != a[ry][rx]: sw_bad += 1
print("  SWEEP (%d non-blank tiles, stride 7 over 0..0x9FFF): %d/%d px match" %
      (sw_nz, sw_total-sw_bad, sw_total))

AS_BUILT_MATCHES = (total_bad == 0 and sw_bad == 0)

# ======================================================================================
# (G) BRUTE FORCE (only if as-built fails) — search the small transform space.
# ======================================================================================
winning = "n/a (as-built matches)"
any_match = AS_BUILT_MATCHES
if not AS_BUILT_MATCHES:
    print("\n=== (G) AS-BUILT FAILED — brute-forcing transform space ===")
    # byte-lane permutations to try for the {planes0-3} -> render mapping.
    # We model render32 = perm(swap(endian_word)) where perm picks 4 source bytes.
    # Use all 24 byte-lane perms (indices into source bytes [b3,b2,b1,b0] = bits[31:24,23:16,15:8,7:0]).
    def apply_perm(x, perm):
        src = [(x>>24)&0xff, (x>>16)&0xff, (x>>8)&0xff, x&0xff]   # [b3,b2,b1,b0]
        o = [src[perm[0]], src[perm[1]], src[perm[2]], src[perm[3]]]
        return (o[0]<<24)|(o[1]<<16)|(o[2]<<8)|o[3]
    perms = list(itertools.permutations(range(4)))
    endians = {"LE": obj0lo_word_LE, "BE": obj0lo_word_BE}
    nwi_variants = {
        "asbuilt {code,~half,row}":   lambda c,r,h: (c<<5)|((0 if h else 1)<<4)|r,
        "half-not-inverted {code,half,row}": lambda c,r,h: (c<<5)|(h<<4)|r,
        "row/half swapped {code,row,~half}": lambda c,r,h: (c<<5)|(r<<1)|(0 if h else 1),
        "row/half swapped {code,row,half}":  lambda c,r,h: (c<<5)|(r<<1)|h,
    }
    # plane4 lane models on the DENSE byte stream (byte @ 0x800000+nwi):
    #   [7:0]  = the dense byte at nwi (as-built / RTL)
    #   [15:8] = the neighbour byte at nwi^1 (the FOLD-era lane bug)
    p4lanes = {"[7:0] (dense byte @nwi)": lambda nwi: obj0hi_byte(nwi),
               "[15:8] (neighbour @nwi^1)": lambda nwi: obj0hi_byte(nwi ^ 1)}
    found = []
    for ename, eread in endians.items():
        for sw in (True, False):
            for perm in perms:
                for nname, nfn in nwi_variants.items():
                    for p4name, p4fn in p4lanes.items():
                        ok = True
                        for code in REF_CODES:
                            gold = golden_tile(code)
                            for row in range(16):
                                if not ok: break
                                ws = []
                                for half in (0,1):
                                    nwi = nfn(code, row, half)
                                    lo  = eread(nwi)
                                    if sw: lo = hwswap16(lo)
                                    lo  = apply_perm(lo, perm)
                                    p4  = p4fn(nwi) & 0xff
                                    ws.append((p4<<32)|lo)
                                rowpx = extract_row_from_words(ws[0], ws[1])
                                if rowpx != gold[row]:
                                    ok = False
                            if not ok: break
                        if ok:
                            found.append((ename, sw, perm, nname, p4name))
    if found:
        any_match = True
        print("  WINNING COMBINATIONS (%d):" % len(found))
        for f in found[:10]:
            print("    endian=%s hwswap=%s perm(b3b2b1b0->)=%s nwi=%s plane4=%s"
                  % (f[0], "on" if f[1] else "off", f[2], f[3], f[4]))
        f = found[0]
        winning = ("endian=%s hwswap=%s plane_permute(src-idx[b3,b2,b1,b0])=%s nwi=%s plane4=%s"
                   % (f[0], "on" if f[1] else "off", f[2], f[3], f[4]))
    else:
        any_match = False
        print("  NO COMBINATION MATCHES — the .mra is NOT delivering expected gfx3. UPSTREAM problem.")
        # evidence dump (use half=1, where tile 0x0f row0 actually has nonzero pens)
        nwi = nwi_asbuilt(0x0f, 0, 1)
        print("  evidence: code=0x0f row0 half1 nwi=0x%x  obj0lo(LE)=%08x obj0hi.byte=%02x" %
              (nwi, obj0lo_word_LE(nwi), obj0hi_byte(nwi)))
        print("            golden row0 =", golden_tile(0x0f)[0])

# ======================================================================================
# (H) ASCII render: golden vs as-built (vs winning if differs) for the non-uniform tile 0x0f.
# ======================================================================================
def ascii_render(grid):
    ramp = " .:-=+*#%@"
    out = []
    for ry in range(16):
        line = "".join(("  " if grid[ry][rx]==0 else "%02x" % grid[ry][rx]) for rx in range(16))
        out.append(line)
    return "\n".join(out)

REND = os.path.join(HERE, "verify_fold_dense_render.txt")
with open(REND, "w") as f:
    code = 0x000f
    f.write("=== tile 0x000f (most non-uniform) ===\n\nGOLDEN (MAME spritelayout_5bpp):\n")
    f.write(ascii_render(golden_tile(code)) + "\n\nAS-BUILT (RTL non-fold path):\n")
    f.write(ascii_render(asbuilt_tile(code)) + "\n")
    if not AS_BUILT_MATCHES and any_match:
        f.write("\n(see stdout for winning transform)\n")
print("\nwrote ASCII render -> %s" % REND)

# Also a tiny PNG (golden|asbuilt side-by-side) using a 5bpp grayscale ramp.
def write_png(path, grids, scale=8):
    cols = len(grids); W = (16*cols + (cols-1)) * scale; Hh = 16*scale
    img = [bytearray(W*3) for _ in range(Hh)]
    for ci, g in enumerate(grids):
        ox = ci*(16+1)*scale
        for ry in range(16):
            for rx in range(16):
                v = g[ry][rx]; lum = int(v * 255 / 31)
                for dy in range(scale):
                    for dx in range(scale):
                        X = ox + rx*scale + dx; Y = ry*scale + dy; o = X*3
                        img[Y][o]=lum; img[Y][o+1]=lum; img[Y][o+2]=lum
    def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
    raw=b"".join(b"\x00"+bytes(r) for r in img)
    open(path,"wb").write(b"\x89PNG\r\n\x1a\n"
        + ch(b"IHDR",struct.pack(">IIBBBBB",W,Hh,8,2,0,0,0))
        + ch(b"IDAT",zlib.compress(raw,9)) + ch(b"IEND",b""))
PNG = os.path.join(HERE, "verify_fold_dense_0f.png")
write_png(PNG, [golden_tile(0x0f), asbuilt_tile(0x0f)])
print("wrote PNG (golden|asbuilt) -> %s" % PNG)

# ======================================================================================
# SUMMARY
# ======================================================================================
print("\n================ VERDICT ================")
print("AS-BUILT byte-exact vs MAME golden : %s" % ("YES" if AS_BUILT_MATCHES else "NO"))
print("AS-BUILT ref-tile match %%          : %.2f" % asbuilt_match_pct)
print("per-code (ref tiles)               : " +
      " ".join("0x%04x:%s" % (c, "OK" if per_code[c]==0 else "%dbad"%per_code[c]) for c in REF_CODES))
if not AS_BUILT_MATCHES:
    print("winning transform                  : %s" % winning)
print("=========================================")
