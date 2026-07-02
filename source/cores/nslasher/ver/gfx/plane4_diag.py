#!/usr/bin/env python3
# Focused diagnostic: WHY does pen-bit-4 (obj0hi / plane4) mismatch when planes0-3 are exact?
# Compares, for reference tiles, the GOLDEN pen-bit-4 plane (raw-ROM MAME decode) against the
# AS-BUILT obj0hi delivery, AND dumps the underlying bytes so the real discrepancy is visible.
import os
ROM = "/path/to/nightslashers/roms"
rf  = lambda n: open(os.path.join(ROM, n), "rb").read()
mbh06, mbh07 = rf("mbh-06.18c"), rf("mbh-07.19c")
print("len(mbh-06)=0x%X  len(mbh-07)=0x%X" % (len(mbh06), len(mbh07)))

# ---- GOLDEN gfx3 region (second half = pen-bit-4 source), exactly as verify_nonfold builds it ----
GFX3 = bytearray(0xa00000)
for i,b in enumerate(mbh06): GFX3[0x500000 + 4*i] = b   # load32 stride 4
for i,b in enumerate(mbh07): GFX3[0x900000 + 4*i] = b
RGN_HALF_BIT = (0xa00000*8)//2
XOFF = [64*8+0,64*8+1,64*8+2,64*8+3,64*8+4,64*8+5,64*8+6,64*8+7, 0,1,2,3,4,5,6,7]
YOFF = [r*32 for r in range(16)]
CHARINC = 128*8
def gbit(ba): return (GFX3[ba>>3] >> (7-(ba&7))) & 1
def golden_p4(code, ry, rx):      # just the high pen bit (PLANEOFFSET[0]=RGN_HALF_BIT)
    return gbit(code*CHARINC + YOFF[ry] + XOFF[rx] + RGN_HALF_BIT)

# ---- AS-BUILT obj0hi: dense mbh-06 then mbh-07 at BA3 rel 0x800000, byte @ nwi={code,~half,row} ----
HI = mbh06 + mbh07                                 # dense concatenation as the .mra delivers
def nwi(code, row, half): return (code<<5) | ((0 if half else 1)<<4) | row
def asbuilt_p4(code, ry, rx):
    half = 0 if rx < 8 else 1                       # half0 = px0-7, half1 = px8-15
    i    = rx if rx < 8 else rx-8
    byte = HI[nwi(code, ry, half)]
    return (byte >> (7-i)) & 1                      # MSB = leftmost pixel (same as obj engine)

for code in (0x0d, 0x0e, 0x0f):
    print("\n==== code 0x%03x : GOLDEN p4  |  AS-BUILT p4 ====" % code)
    bad = 0
    for ry in range(16):
        g = "".join(str(golden_p4(code,ry,rx)) for rx in range(16))
        a = "".join(str(asbuilt_p4(code,ry,rx)) for rx in range(16))
        mark = "" if g==a else "  <-- DIFF"
        bad += sum(1 for k in range(16) if g[k]!=a[k])
        print("  ry%2d  %s | %s%s" % (ry, g, a, mark))
    print("  plane4 bad bits = %d/256" % bad)

# ---- byte-level: dump the source bytes feeding row 0 of code 0x0d, both halves ----
print("\n==== byte-level trace, code 0x0d row0 ====")
for half in (0,1):
    n = nwi(0x0d, 0, half)
    # golden source byte for this half/row:
    rx0 = 0 if half==0 else 8
    ba  = 0x0d*CHARINC + YOFF[0] + XOFF[rx0] + RGN_HALF_BIT
    gbyte_idx = ba>>3
    src = "mbh06" if (gbyte_idx-0x500000)//4 < len(mbh06) and (gbyte_idx>=0x900000)==False else "mbh07"
    print("  half%d nwi=0x%X  AS-BUILT HI[nwi]=0x%02X   GOLDEN region byte@0x%X = 0x%02X (X/4=0x%X)"
          % (half, n, HI[n], gbyte_idx, GFX3[gbyte_idx], (gbyte_idx-0x500000)//4))
