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
    os.path.join(HERE, "nslashers_fold_regen.mra"),     # the FRESH jtframe-generated 8-BYTE-SLOT FOLD .mra
    os.path.join(HERE, "nslashers_dense_regen.mra"),
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
print("regenerated 8-BYTE-SLOT-FOLD blob = 0x%X bytes" % len(BLOB))
assert len(BLOB) >= 0x710000, "regen fold blob too short (no BA3)"

# ======================================================================================
# (C) END-TO-END: carve the 8-BYTE-SLOT-FOLD BA3 straight from the freshly jtframe-generated .mra.
#     The regenerated .mra (nf5 macros.def offsets + jtnslasher_dwnld 8-byte-slot pack) deposits BA3 as
#     ONE 8-byte slot per nwi:
#        32-bit word @(2*nwi)   = planes 0-3 (native)        -> bytes [8*nwi   .. 8*nwi+3]
#        32-bit word @(2*nwi+1) = {pad, plane4_hi-byte, ...} -> bytes [8*nwi+4 .. 8*nwi+7]
#     The MRA delivers plane4 SPREAD as a {0,P4} 16-bit word; interleave2rom emits HIGH byte first, so the
#     plane4 byte lands in byte [8*nwi+5] (the high lane of the low 16-bit half).  The adapter applies
#     hwswap16 on read, so hwswap16(o0_p4word)[7:0] == byte[8*nwi+5] == plane4.  obj1/gfx4 is in BA2 now.
#     This is exactly the image the obj0 2-read FSM reads on HW. We prove the RTL transform is byte-exact
#     vs the MAME spritelayout_5bpp golden.
# ======================================================================================
BA3_START      = 0x710000      # nf5 BA3_START (JTFRAME_BA3_START)
P4BASE_WORDS   = 0x400000      # plane4 SPREAD base in the DOWNLOAD stream (16-bit words) = (SPR1C-BA3)>>1
BA3_SIZE       = 0x1000000     # 16 MB bank (JTFRAME_SDRAM_LARGE)

# The MRA delivers BA3 as the DOWNLOAD STREAM (16-bit words): planes NATIVE @ words [0,P4BASE), plane4
# SPREAD {0,P4} @ words [P4BASE, ..).  jtnslasher_dwnld then REMAPS each 16-bit word into the 8-byte obj0
# slot (this is the on-HW SDRAM image the obj0 FSM reads).  We replay that remap here to build the SDRAM
# image, then read the 8-byte slots (planes word @ byte 8*nwi, plane4 word @ byte 8*nwi+4).
#   planes word W (<P4BASE):  post16 = {W[hi:1],1'b0,W[0]} = ((W>>1)<<2)|(W&1)   (-> 16b words 4nwi,4nwi+1)
#   plane4 word W (>=P4BASE): post16 = 4*(W-P4BASE)+2                            (-> 16b word 4nwi+2)
def build_sdram_image():
    ba3_dl = BLOB[BA3_START:]                         # the download stream for BA3 (byte 0 = BA3-rel 0)
    nwords = len(ba3_dl) // 2
    img = bytearray(BA3_SIZE)                          # 16 MB SDRAM image, byte-addressed
    for W in range(nwords):
        lo = ba3_dl[2*W]; hi = ba3_dl[2*W+1] if (2*W+1) < len(ba3_dl) else 0
        if W < P4BASE_WORDS:                           # planes
            post16 = ((W >> 1) << 2) | (W & 1)
        else:                                          # plane4 spread
            post16 = 4*(W - P4BASE_WORDS) + 2
        o = 2*post16
        if o+1 < BA3_SIZE:
            img[o] = lo; img[o+1] = hi
    return img
BA3 = build_sdram_image()

print("REGEN 8-BYTE-SLOT SDRAM image built via jtnslasher_dwnld remap: 0x%X bytes (16MB bank)" % len(BA3))

N_NWI   = 0x140000
MAX_NWI = N_NWI - 1

def obj0lo_word_LE(nwi):      # planes word: 32b little-endian @ byte 8*nwi  (read#1 of the 8-byte slot)
    o = 8*nwi
    b = BA3[o:o+4]
    return b[0] | (b[1]<<8) | (b[2]<<16) | (b[3]<<24)
def obj0lo_word_BE(nwi):
    o = 8*nwi
    b = BA3[o:o+4]
    return (b[0]<<24) | (b[1]<<16) | (b[2]<<8) | b[3]

def p4word_LE(nwi):           # plane4 word: 32b little-endian @ byte 8*nwi+4  (read#2 of the 8-byte slot)
    o = 8*nwi + 4
    b = BA3[o:o+4]
    return b[0] | (b[1]<<8) | (b[2]<<16) | (b[3]<<24)

def obj0hi_byte(nwi):
    # EXACT FSM model: read#2 targets the plane4 32-bit word @ obj0_addr={nwi,1'b1}=2*nwi+1 (byte 8*nwi+4).
    # The adapter applies hwswap16 on read and takes [7:0]:  hwswap16(d)[7:0] == d[15:8].
    # The MRA's {0,P4} spread put plane4 at 16-bit-word lane that becomes byte[8*nwi+5], so this == plane4.
    d = p4word_LE(nwi)
    return hwswap16(d) & 0xff

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

REND = os.path.join(HERE, "verify_fold_dense_regen_render.txt")
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
PNG = os.path.join(HERE, "verify_fold_dense_regen_0f.png")
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
