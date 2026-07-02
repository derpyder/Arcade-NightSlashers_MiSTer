#!/usr/bin/env python3
# GATE B (obj0 single-fetch repack) -- prove the PHYSICAL 8-byte-slot layout lands byte-exact
# through the REAL loader path. This is THE gate nf5 skipped (its plane4 landed in the wrong
# 16-bit lane after the real big-endian mra2rom interleave).
#
# Chain modeled END-TO-END, from the ACTUAL draft .mra file (mra_fold8_draft.mra):
#   1. authoritative big-endian mra2rom interleave  (interleave2rom, HW-validated for width16)
#   2. the 16-bit-word download stream               (byte b of the blob -> word b>>1, lane b&1)
#   3. the NEW jtnslasher_dwnld BA3 word remap       (planes spread + doubled-p4 slotting)
#   4. the identity byte-lane property               (SDRAM 32b read data lane L = byte 4W+L,
#                                                     proven by the nf4 dense p4 path on HW)
#   5. the NEW single-read FSM model                 (beat0 = planes @8n, p4 = byte 8n+4 = read#2 data[7:0])
#
# PASS requires ALL of:
#   B1  remap injectivity (no two stream words land on the same SDRAM word)
#   B2  slot image identity vs GATE A's abstract BA3 (bytes 8n..8n+4 for every nwi)
#   B3  pixel-exact vs MAME golden (ref tiles + stride-7 sweep) through the new read model
#   B4  obj1/gfx4 BA2 relocation: relocated bytes identical to the proven BA3 image bytes,
#       and the BA2 bit18<->19 tilemap swap provably does NOT touch the obj1 region
import os, re

HERE = os.path.dirname(os.path.abspath(__file__))
def first_existing(*cands):
    for c in cands:
        if os.path.exists(c): return c
    return cands[0]
ROM = first_existing(os.environ.get("ROMDIR",""), "/path/to/nightslashers/roms",
                     "/d/deck/fpga/nightslashers/roms", "/path/to/nightslashers/roms")
PLAIN_MRA = first_existing(
    "/path/to/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra",
    "/d/deck/fpga/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra")
NEW_MRA = os.path.join(HERE, "mra_fold8_draft.mra")
romfile = lambda nm: open(os.path.join(ROM, nm), "rb").read()

# ---- MAME golden (verbatim from the proven verify_fold_dense.py) ----
def build_gfx3_region():
    reg = bytearray(0xa00000)
    def load16(nm, base):
        for i, b in enumerate(romfile(nm)): reg[base + 2*i] = b
    def load32(nm, base):
        for i, b in enumerate(romfile(nm)): reg[base + 4*i] = b
    load16("mbh-02.14c", 0x000001); load16("mbh-04.16c", 0x000000)
    load16("mbh-03.15c", 0x400001); load16("mbh-05.17c", 0x400000)
    load32("mbh-06.18c", 0x500000); load32("mbh-07.19c", 0x900000)
    return bytes(reg)
GFX3 = build_gfx3_region()
RGN_HALF_BIT = (0xa00000 * 8) // 2
PLANEOFFSET  = [RGN_HALF_BIT, 16, 0, 24, 8]
XOFFSET      = [64*8+j for j in range(8)] + list(range(8))
YOFFSET      = [r*32 for r in range(16)]
CHARINC      = 128*8
def gbit(a): return (GFX3[a>>3] >> (7-(a&7))) & 1
def golden_tile(code):
    base=code*CHARINC; grid=[[0]*16 for _ in range(16)]
    for ry in range(16):
        for rx in range(16):
            v=0
            for p in range(5):
                v |= gbit(base+YOFFSET[ry]+XOFFSET[rx]+PLANEOFFSET[p]) << (4-p)
            grid[ry][rx]=v
    return grid

# ---- authoritative big-endian mra2rom blob builder (verbatim; handles single-part interleave) ----
def interleave2rom(width_bits, parts):
    width=width_bits>>3
    fingers=[[data,mapstr,max(int(c) for c in mapstr),0] for data,mapstr in parts]
    sel=[0]*width
    for j in range(width):
        for k in range(len(fingers)):
            if fingers[k][1][j]!='0': sel[j]=k; break
    out=bytearray()
    while True:
        for j in range(width-1,-1,-1):
            f=fingers[sel[j]]; i=f[3]+((ord(f[1][j])-ord('1'))&0xff)
            out.append(f[0][i] if i<len(f[0]) else 0)
        brk=False
        for f in fingers:
            f[3]+=f[2]
            if f[3]>=len(f[0]): brk=True
        if brk: break
    return bytes(out)
def build_blob(mra_path):
    body=re.search(r'<rom index="0"[^>]*>(.*?)</rom>', open(mra_path).read(), re.S).group(1)
    blob=bytearray()
    TOK=re.compile(r'<interleave output="(\d+)">(.*?)</interleave>'
                   r'|<part name="([^"]+)"\s*crc="[^"]*"\s*/>'
                   r'|<part repeat="([^"]+)">\s*([0-9A-Fa-f]+)\s*</part>', re.S)
    for t in TOK.finditer(body):
        if t.group(1):
            parts=[(romfile(nm),mp) for nm,mp in re.findall(r'<part name="([^"]+)"[^>]*map="([^"]*)"', t.group(2))]
            blob+=interleave2rom(int(t.group(1)),parts)
        elif t.group(3): blob+=romfile(t.group(3))
        else: blob+=bytes([int(t.group(5),16)])*int(t.group(4),16)
    return bytes(blob)

# ---- build BOTH blobs: the PLAIN source-of-truth and the NEW nf24 stream ----
SRC_BLOB = build_blob(PLAIN_MRA)
assert len(SRC_BLOB)==0x1110000, "plain blob length mismatch"
SRC = SRC_BLOB[0x610000:]                      # plain BA3: planes @0, p4 dense @0x800000, gfx4 @0xA00000

NEW_BLOB = build_blob(NEW_MRA)
print("nf24 blob = 0x%X bytes (expect 0xE90000)" % len(NEW_BLOB))
assert len(NEW_BLOB)==0xE90000, "nf24 blob length mismatch -- .mra layout wrong"

NEW_BA2_START = 0x210000
NEW_BA3_START = 0x710000
BA2_STREAM = NEW_BLOB[NEW_BA2_START:NEW_BA3_START]     # 0x500000: gfx1 + gfx2 + gfx4
BA3_STREAM = NEW_BLOB[NEW_BA3_START:]                  # 0x780000: planes + doubled p4
assert len(BA2_STREAM)==0x500000 and len(BA3_STREAM)==0x780000

N_NWI = 0x140000

# ---- model the DOWNLOAD through the NEW dwnld remap ----
# BA3 remap (16-bit-word addresses):  w<0x280000 (planes)          -> 4*(w>>1) + (w&1)
#                                     0x280000<=w<0x3C0000 (p4 dbl) -> 4*(w-0x280000) + 2
PLANES_W_END = 0x280000
P4_W_END     = 0x3C0000
def remap_ba3(w):
    if w < PLANES_W_END:  return 4*(w>>1) + (w&1)
    if w < P4_W_END:      return 4*(w-PLANES_W_END) + 2
    return w
# BA2 remap: tilemap bit18<->19 swap only for words < 0x200000 (gfx1+gfx2); identity above (obj1)
def remap_ba2(w):
    if w < 0x200000:
        b18=(w>>18)&1; b19=(w>>19)&1
        return (w & ~((1<<18)|(1<<19))) | (b18<<19) | (b19<<18)
    return w

BA3_SIZE = 0x1000000                            # 16 MB (SDRAM_LARGE)
SDRAM_BA3 = bytearray(b'\xEE'*BA3_SIZE)         # 0xEE = "never written" sentinel
written   = bytearray(BA3_SIZE>>1)              # per-WORD write map for injectivity
inj_fail = 0
for w in range(len(BA3_STREAM)>>1):
    W = remap_ba3(w)
    if written[W]: inj_fail += 1
    written[W] = 1
    SDRAM_BA3[2*W]   = BA3_STREAM[2*w]
    SDRAM_BA3[2*W+1] = BA3_STREAM[2*w+1]
print("\n=== B1: remap injectivity ===")
print("  double-written words: %d  -> %s" % (inj_fail, "PASS" if inj_fail==0 else "FAIL"))
B1 = (inj_fail==0)

SDRAM_BA2 = bytearray(b'\xEE'*0x800000)
for w in range(len(BA2_STREAM)>>1):
    W = remap_ba2(w)
    SDRAM_BA2[2*W]   = BA2_STREAM[2*w]
    SDRAM_BA2[2*W+1] = BA2_STREAM[2*w+1]

# ---- B2: slot image identity vs GATE A's abstract layout (built from the PLAIN source) ----
print("\n=== B2: slot bytes vs GATE A abstract image (all 0x%X nwi) ===" % N_NWI)
bad_planes = bad_p4 = 0
first_bad = None
for nwi in range(N_NWI):
    o = 8*nwi
    if SDRAM_BA3[o:o+4] != SRC[4*nwi:4*nwi+4]:
        bad_planes += 1
        if first_bad is None: first_bad = ("planes", nwi)
    if SDRAM_BA3[o+4] != SRC[0x800000+nwi]:
        bad_p4 += 1
        if first_bad is None: first_bad = ("p4", nwi)
if first_bad: print("  first mismatch:", first_bad)
print("  planes words bad: %d / %d" % (bad_planes, N_NWI))
print("  plane4 bytes bad: %d / %d" % (bad_p4, N_NWI))
B2 = (bad_planes==0 and bad_p4==0)
print("  -> %s" % ("PASS" if B2 else "FAIL"))

# ---- B3: pixel-exact vs MAME golden through the NEW single-read model ----
def hwswap16(x): return (((x>>16)&0xff)<<24)|(((x>>24)&0xff)<<16)|((x&0xff)<<8)|((x>>8)&0xff)
def plane_permute(x): return (((x>>16)&0xff)<<24)|((x&0xff)<<16)|(((x>>24)&0xff)<<8)|((x>>8)&0xff)
def nwi_asbuilt(code,row,half): return (code<<5)|((0 if half else 1)<<4)|row
def render_word(code,row,half):
    nwi=nwi_asbuilt(code,row,half); o=8*nwi
    planes = SDRAM_BA3[o]|(SDRAM_BA3[o+1]<<8)|(SDRAM_BA3[o+2]<<16)|(SDRAM_BA3[o+3]<<24)  # beat0 LE
    p4     = SDRAM_BA3[o+4]                                                              # read#2 data[7:0]
    return (p4<<32) | plane_permute(hwswap16(planes))
def extract_row(w0,w1,bpp=5):
    px=[0]*16
    for half,rw in ((0,w0),(1,w1)):
        for i in range(8):
            v=0
            for p in range(bpp): v |= ((rw>>(8*p+7-i))&1)<<p
            px[half*8+i]=v
    return px
def asbuilt_tile(code):
    return [extract_row(render_word(code,r,0), render_word(code,r,1)) for r in range(16)]

print("\n=== B3: pixel-exact vs MAME golden (new read model) ===")
REF=[0x000d,0x000e,0x000f]
tot=bad=0
for code in REF:
    g=golden_tile(code); a=asbuilt_tile(code); b=0
    for ry in range(16):
        for rx in range(16):
            tot+=1
            if g[ry][rx]!=a[ry][rx]: b+=1; bad+=1
    print("  code=0x%04x : %s (%d/256 px differ)"%(code,"MATCH" if b==0 else "MISMATCH",b))
sw_tot=sw_bad=sw_nz=0
for c in range(0,0xa000,7):
    g=golden_tile(c)
    if not any(g[ry][rx] for ry in range(16) for rx in range(16)): continue
    sw_nz+=1; a=asbuilt_tile(c)
    for ry in range(16):
        for rx in range(16):
            sw_tot+=1
            if g[ry][rx]!=a[ry][rx]: sw_bad+=1
print("  SWEEP (%d non-blank tiles, stride 7): %d/%d px match"%(sw_nz,sw_tot-sw_bad,sw_tot))
B3 = (bad==0 and sw_bad==0)
print("  -> %s" % ("PASS" if B3 else "FAIL"))

# ---- B4: obj1/gfx4 relocation BA3 -> BA2 ----
print("\n=== B4: obj1/gfx4 relocation ===")
GFX4_BA2_REL = 0x400000
gfx4_src = SRC[0xA00000:0xA00000+0x100000]      # the proven bytes the old BA3 path served
gfx4_new = bytes(SDRAM_BA2[GFX4_BA2_REL:GFX4_BA2_REL+0x100000])
ident = (gfx4_new == gfx4_src)
print("  relocated gfx4 bytes identical to proven BA3 image: %s" % ident)
# swap guard: no BA2 word >= 0x200000 may be remapped, and no word < 0x200000 may land >= 0x200000
guard_ok = all(remap_ba2(w)==w for w in range(0x200000, 0x280000, 0x1111)) and \
           all(remap_ba2(w) < 0x200000 for w in range(0, 0x200000, 0x0F37))
print("  bit18<->19 swap confined to tilemap words <0x200000: %s" % guard_ok)
# tilemap image unchanged vs today (same swap, same stream position)
tm_ok = all(SDRAM_BA2[2*remap_ba2(w)] == BA2_STREAM[2*w] for w in range(0, 0x200000, 0x0FA3))
B4 = ident and guard_ok and tm_ok
print("  -> %s" % ("PASS" if B4 else "FAIL"))

# ---- verdict ----
print("\n================ GATE B VERDICT ================")
for nm,v in (("B1 remap injectivity",B1),("B2 slot image identity",B2),
             ("B3 pixel-exact vs golden",B3),("B4 obj1 relocation",B4)):
    print("  %-28s : %s" % (nm, "PASS" if v else "FAIL"))
print("GATE B : %s" % ("PASS" if (B1 and B2 and B3 and B4) else "FAIL"))
print("===============================================")
