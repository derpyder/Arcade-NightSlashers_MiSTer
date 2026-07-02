#!/usr/bin/env python3
# GATE A (obj0 single-fetch repack) -- prove the NEW 8-byte-slot packing + single-read model is
# byte-exact vs the MAME golden. Inherits the PROVEN nf4 machinery (golden decode, authoritative
# big-endian mra2rom blob, byte transform) VERBATIM from verify_fold_dense.py -- ONLY the BA3 image
# layout and the read model change:
#
#   nf4 DENSE (current, proven 1495296/1495296): planes word @ byte 4*nwi ; plane4 byte @ 0x500000+nwi
#                                                 (2 reads: planes @nwi, plane4 word @0x140000+nwi>>2)
#   NEW 8-BYTE-SLOT (single burst):              per nwi an 8-byte line: planes @ 8*nwi..+3 ;
#                                                 plane4 byte @ 8*nwi+4 ; +5..+7 = pad.
#                                                 ONE DW32-DOUBLE burst at obj0_addr=2*nwi delivers
#                                                 beat0=planes word (byte 8*nwi), beat1=plane4 word (byte 8*nwi+4).
#
# The plane BYTES and the transform are UNCHANGED -- only relocated. So this MUST pass 100% by
# construction; if it doesn't, the packing/addressing math is wrong and we STOP before any RTL.
# (This is the "packing math" gate; the download byte-LANE gate that nf5 skipped is GATE B, separate.)
import os, re, itertools, struct, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
def first_existing(*cands):
    for c in cands:
        if os.path.exists(c): return c
    return cands[0]
ROM = first_existing(os.environ.get("ROMDIR",""), "/path/to/nightslashers/roms",
                     "/d/deck/fpga/nightslashers/roms", "/path/to/nightslashers/roms")
MRA = first_existing(
    "/path/to/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra",
    "/d/deck/fpga/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra")
romfile = lambda nm: open(os.path.join(ROM, nm), "rb").read()

# ---- (A) MAME golden (identical to verify_fold_dense.py) ----
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

# ---- (B) authoritative big-endian mra2rom blob (identical) ----
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
def build_blob():
    body=re.search(r'<rom index="0"[^>]*>(.*?)</rom>', open(MRA).read(), re.S).group(1)
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
BLOB=build_blob()
assert len(BLOB)==0x1110000, "blob length mismatch"

# ---- (C) carve the PROVEN source bytes, then BUILD the NEW 8-byte-slot BA3 image ----
BA3_START=0x610000
SRC=BLOB[BA3_START:]
assert all(b==0xFF for b in SRC[0x500000:0x800000]), "SRC pad sanity FAILED"
N_NWI=0x140000                       # planes region 0x140000 words; plane4 stream 0x140000 bytes
SRC_PLANES_OFF=0x000000
SRC_P4_OFF=0x800000                  # plain-MRA source plane4 dense byte stream

# NEW layout: 8 bytes per nwi.  16MB bank (SDRAM_LARGE) required: 8*0x140000 = 0xA00000 (10MB) > 8MB.
SLOT=8
BA3_SIZE=0x1000000                   # 16MB (SDRAM_LARGE)
assert SLOT*N_NWI <= BA3_SIZE, "8-byte-slot overflows 16MB"
BA3=bytearray(b'\xFF'*BA3_SIZE)
for nwi in range(N_NWI):
    o=SLOT*nwi
    BA3[o:o+4]=SRC[SRC_PLANES_OFF+4*nwi : SRC_PLANES_OFF+4*nwi+4]   # planes word  -> 8*nwi
    BA3[o+4]=SRC[SRC_P4_OFF+nwi]                                     # plane4 byte  -> 8*nwi+4
print("NEW 8-byte-slot BA3 built: planes @8*nwi, plane4 @8*nwi+4, %d nwi, bank=0x%X (16MB)"%(N_NWI,BA3_SIZE))

# ---- (D) NEW single-read model: obj0_addr=2*nwi DW32-DOUBLE => beat0=planes(byte 8*nwi), beat1=plane4(byte 8*nwi+4) ----
def planes_word_LE(nwi):             # beat0: little-endian 32b at byte 8*nwi
    b=BA3[SLOT*nwi:SLOT*nwi+4]; return b[0]|(b[1]<<8)|(b[2]<<16)|(b[3]<<24)
def p4_byte(nwi):                    # beat1 low byte @ 8*nwi+4
    return BA3[SLOT*nwi+4]
def hwswap16(x): return (((x>>16)&0xff)<<24)|(((x>>24)&0xff)<<16)|((x&0xff)<<8)|((x>>8)&0xff)
def plane_permute(x): return (((x>>16)&0xff)<<24)|((x&0xff)<<16)|(((x>>24)&0xff)<<8)|((x>>8)&0xff)
def nwi_asbuilt(code,row,half): return (code<<5)|((0 if half else 1)<<4)|row
def render_word(code,row,half):
    nwi=nwi_asbuilt(code,row,half)
    return (p4_byte(nwi)<<32) | plane_permute(hwswap16(planes_word_LE(nwi)))
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

# ---- (E) verify vs golden: ref tiles + full sweep ----
REF=[0x000d,0x000e,0x000f]
print("\n=== GATE A: 8-byte-slot single-read vs MAME golden ===")
tot=bad=0; perplane=[0]*5
for code in REF:
    g=golden_tile(code); a=asbuilt_tile(code); b=0
    for ry in range(16):
        for rx in range(16):
            tot+=1
            if g[ry][rx]!=a[ry][rx]:
                b+=1; bad+=1
                for p in range(5):
                    if ((g[ry][rx]^a[ry][rx])>>p)&1: perplane[p]+=1
    print("  code=0x%04x : %s (%d/256 px differ)"%(code,"MATCH" if b==0 else "MISMATCH",b))
print("  per-plane mismatch: "+" ".join("p%d=%d"%(p,perplane[p]) for p in range(5)))
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
PASS=(bad==0 and sw_bad==0)
print("\n================ GATE A VERDICT ================")
print("8-byte-slot single-read byte-exact vs golden : %s"%("PASS" if PASS else "FAIL"))
print("  ref tiles bad=%d  sweep bad=%d"%(bad,sw_bad))
print("===============================================")
