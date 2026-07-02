#!/usr/bin/env python3
# GATE C preload + vectors for tb_obj0_combined_verify.v — nf24 SINGLE-FETCH 8-byte-slot fold.
#
# THE DISCIPLINE THAT nf5's SIM LACKED: the SDRAM image here is NOT hand-modeled. It is produced by
# the SAME chain GATE B proved (ver/gfx/verify_fold8_gateB.py): the ACTUAL draft .mra
# (ver/gfx/mra_fold8_draft.mra) -> authoritative big-endian mra2rom interleave -> the NEW
# jtnslasher_dwnld BA3 word remap -> flat SDRAM bytes. The goldens are the pre-existing HW-proven
# 40-bit render-word contract (ver/gfx/gfx3_spr.hex) the obj engine TBs validate against MAME pixels.
# If the .mra, the dwnld remap, or the FSM lane select is wrong, this sim CANNOT pass.
#
# Capacity: one mt48lc16m16a2 bank = 4M x 16 words, so keep tiles with slot top word 4*nwi+3 < 0x400000
# (nwi < 0x100000, ~768 of 1440 golden tiles, real 20-bit addressing). nwi >= 0x100000 is covered by
# GATE B's full-range byte-identity (B2, all 0x140000 nwi).
#
# The unwritten slot word 4*nwi+3 (bytes 8n+6/7) is stuffed with the 0xEEEE sentinel: the download
# never writes it on HW (garbage there), so the sim must prove the RTL never consumes it.
import os, re

D    = os.path.dirname(os.path.abspath(__file__))
GFX  = os.path.join(D, "..", "gfx")
ROM  = next(p for p in ["/path/to/nightslashers/roms", "/d/deck/fpga/nightslashers/roms",
                        "/path/to/nightslashers/roms"] if os.path.exists(p))
PLAIN_MRA = next(p for p in [
    "/path/to/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra",
    "/d/deck/fpga/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra"]
    if os.path.exists(p))
NEW_MRA = os.path.join(GFX, "mra_fold8_draft.mra")
romfile = lambda nm: open(os.path.join(ROM, nm), "rb").read()

# ---- the GATE-B chain, verbatim (authoritative big-endian mra2rom + the dwnld remap) ----
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

NEW_BLOB = build_blob(NEW_MRA)
assert len(NEW_BLOB)==0xE90000, "nf24 blob length mismatch"
BA3_STREAM = NEW_BLOB[0x710000:]
assert len(BA3_STREAM)==0x780000

def remap_ba3(w):                     # == jtnslasher_dwnld.v BA3 case
    if w < 0x280000: return 4*(w>>1) + (w&1)
    if w < 0x3C0000: return 4*(w-0x280000) + 2
    return w

BA3_SIZE = 0x1000000
IMG = bytearray(b'\xEE'*BA3_SIZE)     # 0xEE = "never written" sentinel (survives into 4n+3 words)
for w in range(len(BA3_STREAM)>>1):
    W = remap_ba3(w)
    IMG[2*W]   = BA3_STREAM[2*w]
    IMG[2*W+1] = BA3_STREAM[2*w+1]

# ---- cross-check vs the plain-MRA source (ties this preload to the GATE B proof) ----
SRC = build_blob(PLAIN_MRA)[0x610000:]
for nwi in range(0, 0x140000, 0x97):  # dense sample sweep
    assert IMG[8*nwi:8*nwi+4] == SRC[4*nwi:4*nwi+4], "planes drift vs GATE B at nwi=%x"%nwi
    assert IMG[8*nwi+4]       == SRC[0x800000+nwi],  "plane4 drift vs GATE B at nwi=%x"%nwi
print("cross-check vs plain-MRA source: OK (sampled)")

# ---- vectors + goldens (the HW-proven 40-bit contract) ----
def load_hex(path):
    out = {}; addr = 0
    for l in open(path):
        l = l.strip()
        if not l: continue
        if l[0] == '@': addr = int(l[1:], 16); continue
        out[addr] = int(l, 16); addr += 1
    return out
o0 = load_hex(os.path.join(GFX, "gfx3_spr.hex"))            # hra -> 40-bit golden render word

def fsm_nwi(a):                        # jtnslasher_sdram.v: nwi = {a[20:5], ~a[0], a[4:1]}
    return ((a >> 5) << 5) | ((0 if (a & 1) else 1) << 4) | ((a >> 1) & 0xf)

BANK_CAP = 0x400000                    # one mt48lc16m16a2 bank (16-bit words)
hras = sorted(h for h in o0 if fsm_nwi(h)*4 + 3 < BANK_CAP)

sdram = {}                             # sparse 16-bit-word image for $readmemh
tv_addr, tv_gold = [], []
for hra in hras:
    nwi  = fsm_nwi(hra)
    base = nwi * 4
    for k in range(4):                 # slot words 4n..4n+3 straight from the GATE-B image bytes
        sdram[base+k] = IMG[2*(base+k)] | (IMG[2*(base+k)+1] << 8)
    tv_addr.append(hra)
    tv_gold.append(o0[hra])

with open(os.path.join(D, "sdram_bank3.hex"), "w") as f:
    prev = None
    for a in sorted(sdram):
        if a != prev: f.write("@%X\n" % a)
        f.write("%04X\n" % sdram[a])
        prev = a + 1
with open(os.path.join(D, "objfold_real_addr.hex"), "w") as f:
    for a in tv_addr: f.write("%06x\n" % a)
with open(os.path.join(D, "objfold_real_gold.hex"), "w") as f:
    for g in tv_gold: f.write("%010x\n" % g)
with open(os.path.join(D, "objfold_real_n.vh"), "w") as f:
    f.write("`define OBJFOLD_N %d\n" % len(hras))

nz = sum(1 for g in tv_gold if g != 0)
print("tiles=%d (of %d golden, %d non-blank)  max nwi=0x%X  max SDRAM word=0x%X (cap 0x%X)"
      % (len(hras), len(o0), nz, max(fsm_nwi(h) for h in hras), max(sdram), BANK_CAP-1))
print("wrote sdram_bank3.hex objfold_real_addr.hex objfold_real_gold.hex objfold_real_n.vh")
