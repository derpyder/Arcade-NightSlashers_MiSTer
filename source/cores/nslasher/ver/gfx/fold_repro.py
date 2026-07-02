#!/usr/bin/env python3
# ============================================================================
# FAITHFUL end-to-end offline repro of the obj0 BANDWIDTH-FOLD path.
#
# Goal: reproduce the HW sprite garble (Jake's body tiles render as hair tiles
# = tile-address aliasing) OFFLINE, using the REAL ROMs + the REAL .mra byte
# order + the REAL download RTL + the REAL FSM fetch, and check ALL tile codes
# (not just the 1440 "used" golden tiles the existing validators check).
#
# Pipeline modeled (each stage = exact copy of the named source):
#   1. .mra BA3 stream  : nslashers_FOLD.mra  (interleave maps, FF pad)  -> 16-bit words
#   2. download post_addr: jtnslasher_dwnld.v  (BA3 branch)              -> SDRAM 16-bit words
#   3. FSM fetch         : jtnslasher_sdram.v  (obj0_nwi + 2-read + assemble) -> 40-bit word
#   4. compare to golden : gfx3_spr.hex   for ALL codes in range, characterize aliasing
# ============================================================================
import os, sys
d = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", r"/path/to/nightslashers/mame-dump/roms/nslashers")
rd = lambda f: open(os.path.join(ROM, f), 'rb').read()

# ---------------------------------------------------------------------------
# STEP 0: load golden (the validated render-format 40-bit obj0 words)
# ---------------------------------------------------------------------------
def load_hex(name):
    out = {}; a = 0
    for l in open(os.path.join(d, name)):
        l = l.strip()
        if not l: continue
        if l[0] == '@': a = int(l[1:], 16); continue
        out[a] = int(l, 16); a += 1
    return out

golden = load_hex("gfx3_spr.hex")      # hra = code*32 + rowf*2 + half -> 40-bit
print("golden tiles (hra entries): %d ; max hra=%#x (max code=%#x)" %
      (len(golden), max(golden), max(golden)//32))

# ===========================================================================
# STEP 1: assemble the REAL .mra BA3 stream (16-bit words within BA3).
#
# MiSTer MRA <interleave output="16"> semantics: each part's map="ab" string has
# one char per OUTPUT BYTE, leftmost = high byte. Digit d (1-based) = take the
# d-th input byte of this part for that output-byte lane; 0 = this part does not
# contribute (lane filled by the OTHER part or 0).
#   map="01": part -> LOW  byte (hi lane skipped)
#   map="10": part -> HIGH byte (lo lane skipped)
# A single-part interleave with map="10" (obj0hi6/7) => SPREAD: each input byte
# becomes one 16-bit word {input_byte, 00}.
#
# .mra layout (byte addresses within BA3, BA3_START=0x710000):
#   sprites1a @0x000000 : interleave(mbh-02 map01 -> lo, mbh-04 map10 -> hi)  len 0x400000
#   sprites1b @0x400000 : interleave(mbh-03 map01 -> lo, mbh-05 map10 -> hi)  len 0x400000
#   FF pad    @0x800000 : repeat 0x300000 of 0xFF
#   obj0hi6   @0xB00000 : interleave(mbh-06 map10) SPREAD  (1MB -> 2MB)
#   obj0hi7   @0xF00000 : interleave(mbh-07 map10) SPREAD  (0.25MB -> 0.5MB)
# (BA3 byte offsets = mra addr - 0x710000.)
# ===========================================================================
def interleave2(part_lo, part_hi):
    """output=16: lo-byte stream + hi-byte stream -> bytes [lo0,hi0,lo1,hi1,...]."""
    n = min(len(part_lo), len(part_hi))
    out = bytearray(2*n)
    for i in range(n):
        out[2*i]   = part_lo[i]      # low  byte (even address)
        out[2*i+1] = part_hi[i]      # high byte (odd  address)
    return bytes(out)

def spread_hi(part):
    """single-part output=16 map=10: each input byte -> {byte,00} = bytes [00,b0,00,b1,...]."""
    out = bytearray(2*len(part))
    for i, b in enumerate(part):
        out[2*i]   = 0x00            # low byte unused
        out[2*i+1] = b               # high byte = the spread plane4 byte
    return bytes(out)

mbh02 = rd("mbh-02.14c"); mbh04 = rd("mbh-04.16c")   # 2MB each
mbh03 = rd("mbh-03.15c"); mbh05 = rd("mbh-05.17c")   # 0.5MB each
mbh06 = rd("mbh-06.18c"); mbh07 = rd("mbh-07.19c")   # 1MB, 0.25MB

sprites1a = interleave2(mbh02, mbh04)   # mbh-02->lo, mbh-04->hi ; 2*2MB = 4MB
sprites1b = interleave2(mbh03, mbh05)   # mbh-03->lo, mbh-05->hi ; 2*0.5MB = 1MB
ffpad     = b'\xFF' * 0x300000
obj0hi6   = spread_hi(mbh06)            # 1MB -> 2MB
obj0hi7   = spread_hi(mbh07)            # 0.25MB -> 0.5MB

# Build BA3 honoring the EXPLICIT START offsets the .mra lists (BA3-relative).
# The <part repeat="0x300000"> FF pad sits between sprites1b and obj0hi6, so the
# next region always begins at its fixed START offset regardless of part length.
# NOTE: SPR1C (obj0hi6) starts at BA3 byte 0x800000 = 16-bit WORD 0x400000 =
# exactly P4BASE -> the plane4 spread region begins precisely at P4BASE. ✓
def ba3_off(start_abs): return start_abs - 0x710000
SPR1A = ba3_off(0x710000)   # 0x000000
SPR1B = ba3_off(0xB10000)   # 0x400000
SPR1C = ba3_off(0xF10000)   # 0x800000  (obj0hi6) -- AFTER the 0x300000 FF pad
SPR1D = ba3_off(0x1110000)  # 0xC00000  (obj0hi7)
END   = ba3_off(0x1190000)  # 0xA80000? -> 0x1190000-0x710000 = 0xA80000

BA3 = bytearray(END)
def blit(off, data):
    BA3[off:off+len(data)] = data
blit(SPR1A, sprites1a)                    # 0x000000 .. 0x400000 (exact 4MB)
blit(SPR1B, sprites1b)                    # 0x400000 .. 0x500000 (1MB) ; 0x500000..0x800000 = FF pad
for i in range(SPR1B+len(sprites1b), SPR1C): BA3[i] = 0xFF   # explicit FF pad region
blit(SPR1C, obj0hi6)                      # 0x800000 .. 0xA00000 (2MB)
blit(SPR1D, obj0hi7)                      # 0xC00000 .. 0xC80000 (0.5MB)

print("BA3 assembled: %d bytes (%.2f MB). SPR1A=%#x SPR1B=%#x SPR1C=%#x SPR1D=%#x END=%#x" %
      (len(BA3), len(BA3)/(1<<20), SPR1A, SPR1B, SPR1C, SPR1D, END))

# BA3 as 16-bit words (little-endian within the download byte stream: the .mra
# interleave wrote lo byte at even addr, hi at odd; the download streams BYTES
# and prog_addr is the 16-bit-WORD index, prog_data the byte). The post_addr
# transform is WORD-granular and lane-preserving, so model at byte granularity.
NWORDS = len(BA3)//2
def ba3_word(w):    # 16-bit word w (lo=even byte, hi=odd byte)
    return BA3[2*w] | (BA3[2*w+1] << 8)

# ===========================================================================
# STEP 2: apply the REAL download post_addr (jtnslasher_dwnld.v BA3 branch).
#   planes (w < P4BASE): post = {w[21:1],1'b0,w[0]}  -> insert 0 at bit1
#   plane4 (w >= P4BASE): nwi=w-P4BASE ; post = {nwi,2'b10} = 4*nwi+2
#   P4BASE = 0x40_0000 (16-bit words)
# prog_data is byte-streamed: the DOWNLOAD remaps the 16-bit WORD address; the
# byte LANE (hi/lo) is preserved. So SDRAM 16-bit word post = the input word w's
# 16 bits placed at word index post_addr(w).
# ===========================================================================
P4BASE = 0x40_0000
def post_addr_word(w):
    if w < P4BASE:
        return ((w >> 1) << 2) | (w & 1)        # {w[hi:1],0,w[0]}
    else:
        nwi = w - P4BASE
        return 4*nwi + 2                          # {nwi,2'b10}

# Build the modeled SDRAM as a dict of 16-bit words (sparse; 0 default).
# IMPORTANT: the post_addr for planes can reach up to ~ (P4BASE-1)*2 ~= 0x800000*... ;
# we only need the words the FSM will actually fetch, but to faithfully catch
# COLLISIONS we build everything the .mra delivers.
SDRAM = {}
for w in range(NWORDS):
    val = ba3_word(w)
    SDRAM[post_addr_word(w)] = val

def sdram_word(pw):
    return SDRAM.get(pw, 0)

# ===========================================================================
# STEP 3: FSM fetch (jtnslasher_sdram.v).
#   obj0_nwi = { addr[20:5], ~addr[0], addr[4:1] }     (addr = hra = {code,rowf,half})
#   planes 32-bit word @ obj0_addr={nwi,1'b0} = nwi*2 (32-bit) = 16b words [4nwi,4nwi+1]
#   plane4 32-bit word @ obj0_addr={nwi,1'b1} = nwi*2+1       = 16b words [4nwi+2,4nwi+3]
#   assemble: { p4word[7:0], plane_permute(hwswap16(planes)) }
#     plane_permute(d) = {d[23:16],d[7:0],d[31:24],d[15:8]}
#     hwswap16(d)      = {d[23:16],d[31:24],d[7:0],d[15:8]}
# ===========================================================================
def obj0_nwi(hra):
    a = hra
    code = (a >> 5) & 0xFFFF        # addr[20:5]
    half = a & 1                    # addr[0]
    rowf = (a >> 1) & 0xF           # addr[4:1]
    return (code << 5) | ((half ^ 1) << 4) | rowf   # {code,~half,rowf}

def plane_permute(dw):
    d31_24=(dw>>24)&0xff; d23_16=(dw>>16)&0xff; d15_8=(dw>>8)&0xff; d7_0=dw&0xff
    return (d23_16<<24)|(d7_0<<16)|(d31_24<<8)|d15_8
def hwswap16(dw):
    d31_24=(dw>>24)&0xff; d23_16=(dw>>16)&0xff; d15_8=(dw>>8)&0xff; d7_0=dw&0xff
    return (d23_16<<24)|(d31_24<<16)|(d7_0<<8)|d15_8

def fold_fetch(hra):
    """Return the 40-bit obj0 word the REAL fold path produces for engine addr hra."""
    nwi = obj0_nwi(hra)
    # planes 32-bit word = nwi*2 (32-bit words) = 16b words [4nwi, 4nwi+1]
    pw_planes32 = nwi*2
    plo16 = sdram_word(pw_planes32*2 + 0)   # 16b word index = (32b word)*2
    phi16 = sdram_word(pw_planes32*2 + 1)
    planes = plo16 | (phi16 << 16)
    # plane4 32-bit word = nwi*2+1 = 16b words [4nwi+2, 4nwi+3]
    pw_p432 = nwi*2 + 1
    p4lo16 = sdram_word(pw_p432*2 + 0)      # plane4 in low byte of word [4nwi+2]
    p4word = p4lo16                          # low 16b; FSM uses [7:0]
    planes_render = plane_permute(hwswap16(planes))
    return (p4word & 0xff) << 32 | planes_render

# ===========================================================================
# STEP 4: compare to golden for ALL hra in golden, then characterize aliasing.
# ===========================================================================
bad = 0; n = 0; mism = []
for hra, gold in sorted(golden.items()):
    n += 1
    got = fold_fetch(hra)
    if got != gold:
        bad += 1
        if len(mism) < 12: mism.append((hra, gold, got))
print("\n=== STEP 4a: fold_fetch vs golden over the %d USED tiles ===" % n)
print("   %s : %d/%d match" % ("BIT-EXACT" if bad==0 else "%d MISMATCH"%bad, n-bad, n))
for hra,g,go in mism:
    print("   hra=%#07x code=%#x rowf=%d half=%d  gold=%010x  got=%010x" %
          (hra, hra>>5, (hra>>1)&0xf, hra&1, g, go))

if __name__ == "__main__":
    pass
