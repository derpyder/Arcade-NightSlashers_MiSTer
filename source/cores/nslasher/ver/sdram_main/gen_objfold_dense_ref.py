#!/usr/bin/env python3
# CALIBRATION baseline for tb_obj0_gateE_dense.v — the nf23 DENSE 2-read layout image
# (planes word @ byte 4*nwi ; plane4 dense byte-stream @ BA3-rel 0x500000), built from the SAME
# plain-MRA source bytes as the gate-B/C image. Vectors/goldens = the SAME set gen_objfold_gateC.py
# emits (run it first). Purpose: run the OLD design through the SAME contention harness so the
# old/new latency ratio can be compared against the HW-measured 46-66 clk (nf23 probe).
import os, re

D    = os.path.dirname(os.path.abspath(__file__))
GFX  = os.path.join(D, "..", "gfx")
ROM  = next(p for p in ["/path/to/nightslashers/roms", "/d/deck/fpga/nightslashers/roms",
                        "/path/to/nightslashers/roms"] if os.path.exists(p))
PLAIN_MRA = next(p for p in [
    "/path/to/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra",
    "/d/deck/fpga/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB).mra"]
    if os.path.exists(p))
romfile = lambda nm: open(os.path.join(ROM, nm), "rb").read()

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

SRC = build_blob(PLAIN_MRA)[0x610000:]

def load_hex(path):
    out = {}; addr = 0
    for l in open(path):
        l = l.strip()
        if not l: continue
        if l[0] == '@': addr = int(l[1:], 16); continue
        out[addr] = int(l, 16); addr += 1
    return out
o0 = load_hex(os.path.join(GFX, "gfx3_spr.hex"))
def fsm_nwi(a):
    return ((a >> 5) << 5) | ((0 if (a & 1) else 1) << 4) | ((a >> 1) & 0xf)

BANK_CAP = 0x400000
hras = sorted(h for h in o0 if fsm_nwi(h)*4 + 3 < BANK_CAP)   # SAME tile set as gateC

# dense image: planes @ byte 4*nwi ; p4 dense byte @ 0x500000+nwi (word 0x280000+(nwi>>1))
sdram = {}
for hra in hras:
    nwi = fsm_nwi(hra)
    for k in range(2):    # planes 16-bit words 2*nwi, 2*nwi+1
        b = 4*nwi + 2*k
        sdram[2*nwi+k] = SRC[b] | (SRC[b+1]<<8)
    # the p4 word covering this nwi (dense: 4 p4 bytes / 32b word -> two 16-bit words)
    p4b = 0x500000 + (nwi & ~3)
    wbase = p4b >> 1
    for k in range(2):
        sdram[wbase+k] = SRC[0x800000+(nwi&~3)+2*k] | (SRC[0x800000+(nwi&~3)+2*k+1]<<8)

with open(os.path.join(D, "sdram_bank3_dense.hex"), "w") as f:
    prev = None
    for a in sorted(sdram):
        if a != prev: f.write("@%X\n" % a)
        f.write("%04X\n" % sdram[a])
        prev = a + 1
print("dense-ref image: %d words, max word 0x%X ; tiles=%d (same set as gateC)"
      % (len(sdram), max(sdram), len(hras)))
