#!/usr/bin/env python3
# Validate the DOWNLOAD PACK logic for the obj0 fold (build-free). Models the BA3 download stream the MRA
# delivers (planes native + plane4 SPREAD) + the jtnslasher_dwnld post_addr remap, builds the resulting
# SDRAM image, and checks it holds the NATIVE 8-byte slots the (already-verified) adapter renders:
#   sdram16[4nwi], [4nwi+1] = planes_native[nwi] (low,high 16)   ; sdram16[4nwi+2] = {0, plane4[nwi]}
# The adapter applies hwswap16 on READ (HW delivery artifact), so the download writes NATIVE.
import os
d = os.path.dirname(os.path.abspath(__file__))
def load_hex(name):
    out={}; a=0
    for l in open(os.path.join(d,name)):
        l=l.strip()
        if not l: continue
        if l[0]=='@': a=int(l[1:],16); continue
        out[a]=int(l,16); a+=1
    return out
lo_n = load_hex("obj0lo_native.hex")   # nwi -> native planes 32-bit word
hi_n = load_hex("obj0hi_native.hex")   # nwi -> native plane4 byte

max_nwi = max(lo_n)
PLANE4_W_BASE = 2*max_nwi + 2          # plane4 spread region starts right after planes (16-bit-word base)

# ---- the BA3 download stream (16-bit words), as the MRA delivers it (NATIVE) ----
src = {}
for nwi, w32 in lo_n.items():
    src[2*nwi]   = w32 & 0xFFFF                       # planes low 16
    src[2*nwi+1] = (w32 >> 16) & 0xFFFF               # planes high 16
for nwi, p4 in hi_n.items():
    src[PLANE4_W_BASE + nwi] = p4 & 0xFF              # plane4 SPREAD: {0, P4} (P4 in low byte)

# ---- jtnslasher_dwnld post_addr (16-bit-word remap), BA3 obj0 fold ----
def post_addr(w):
    if w < PLANE4_W_BASE:                              # planes: insert a 0 at bit1 -> 4nwi / 4nwi+1
        return ((w >> 1) << 2) | (w & 1)
    else:                                             # plane4 spread: word(nwi) -> 4nwi+2
        nwi = w - PLANE4_W_BASE
        return 4*nwi + 2

# build SDRAM image + check bijection
sdram = {}
collide = 0
for w, val in src.items():
    dst = post_addr(w)
    if dst in sdram and sdram[dst] != val:
        collide += 1
        if collide <= 4: print("  COLLISION dst=%#x from src %#x (val %x vs %x)" % (dst, w, val, sdram[dst]))
    sdram[dst] = val

# verify the native 8-byte slots
bad = 0; n = 0
for nwi in lo_n:
    n += 1
    plo = sdram.get(4*nwi, 0); phi = sdram.get(4*nwi+1, 0)
    planes = (phi << 16) | plo
    p4w = sdram.get(4*nwi+2, 0)
    if planes != lo_n[nwi] or (p4w & 0xFF) != hi_n.get(nwi, 0):
        bad += 1
        if bad <= 4:
            print("  MISMATCH nwi=%#x planes got=%08x exp=%08x  p4 got=%02x exp=%02x"
                  % (nwi, planes, lo_n[nwi], p4w & 0xFF, hi_n.get(nwi, 0)))

print("download-pack: planes word remap = {w[hi:1],0,w[0]}  ; plane4 spread word -> 4nwi+2")
print("  PLANE4_W_BASE = %#x  (max_nwi=%#x)" % (PLANE4_W_BASE, max_nwi))
print("  bijection: %s (%d collisions)" % ("OK" if collide==0 else "FAIL", collide))
print("  native slots: %s (%d/%d tiles)" % ("BIT-EXACT" if bad==0 else "%d BAD"%bad, n-bad, n))
print("RESULT:", "DOWNLOAD PACK LOGIC VERIFIED" if (bad==0 and collide==0) else "*** FAILED ***")
