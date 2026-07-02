#!/usr/bin/env python3
# Byte-order faithfulness check for the obj0 FOLD (investigation, sim-only).
# GROUND TRUTH for what the real SDRAM holds = obj0lo_native.hex / obj0hi_native.hex, which
# validate_fold_mra.py already proved BYTE-EXACT against the real MRA->dwnll->SDRAM chain:
#   SDRAM word (nwi*4+0) = native planes low half  = obj0lo[nwi][15:0]
#   SDRAM word (nwi*4+1) = native planes high half = obj0lo[nwi][31:16]
#   SDRAM word (nwi*4+2) = { 0x00, plane4 }        = obj0hi[nwi] in the LOW byte
#   SDRAM word (nwi*4+3) = unwritten pad (FF fill on HW)
# We then model the HW per-16-bit BYTESWAP on delivery and the obj0 FSM unpack, and compare to golden.
import os
D   = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.join(D, "..", "gfx")

def load_hex(path):
    out = {}; a = 0
    for l in open(path):
        l = l.strip()
        if not l: continue
        if l[0] == '@': a = int(l[1:], 16); continue
        out[a] = int(l, 16); a += 1
    return out

gold = load_hex(os.path.join(GFX, "gfx3_spr.hex"))          # hra -> 40-bit golden
lo_n = load_hex(os.path.join(GFX, "obj0lo_native.hex"))     # nwi -> native planes 32b
hi_n = load_hex(os.path.join(GFX, "obj0hi_native.hex"))     # nwi -> native plane4 byte

def remap_native_nwi(hra):
    code = hra >> 5; rowf = (hra >> 1) & 0xf; half = hra & 1
    return code*32 + rowf + (0 if half else 16)

def sdram_words(nwi):
    p = lo_n.get(nwi, 0) & 0xFFFFFFFF       # native planes word b0|b1<<8|b2<<16|b3<<24
    p4 = hi_n.get(nwi, 0) & 0xFF
    return [p & 0xFFFF, (p >> 16) & 0xFFFF, 0x0000 | p4, 0xFFFF]  # native SDRAM, low byte=plane4, pad=FF

def bswap16(w): return ((w & 0xFF) << 8) | (w >> 8)

def plane_permute(d):   # RTL { d[23:16], d[7:0], d[31:24], d[15:8] } (MSB-first concat)
    b = [(d>>0)&0xff,(d>>8)&0xff,(d>>16)&0xff,(d>>24)&0xff]   # b[k] = byte k
    return (b[2]<<24) | (b[0]<<16) | (b[3]<<8) | b[1]

def hwswap16_32(d):     # RTL { d[23:16], d[31:24], d[7:0], d[15:8] } (MSB-first concat)
    b = [(d>>0)&0xff,(d>>8)&0xff,(d>>16)&0xff,(d>>24)&0xff]
    return (b[2]<<24) | (b[3]<<16) | (b[0]<<8) | b[1]

def fsm_render(nwi, hw_byteswap):
    sw = sdram_words(nwi)
    dw = [bswap16(x) for x in sw] if hw_byteswap else sw[:]
    planes_word = (dw[1] << 16) | dw[0]      # bcache {beat2(4n+1), beat1(4n)}
    p4word      = (dw[3] << 16) | dw[2]
    o0_planes = hwswap16_32(planes_word)
    o0_p4_un  = hwswap16_32(p4word)
    return (((o0_p4_un & 0xff) << 32) | plane_permute(o0_planes))

nz = [(h,g) for h,g in sorted(gold.items()) if g != 0]
print("nonzero golden tiles:", len(nz), "of", len(gold))
for label, hb in [("(A) HW byteswap ON  (FSM hwswap16 assumption)", True),
                  ("(B) HW byteswap OFF (native delivery)         ", False)]:
    bad = 0; first = None
    for hra, g in nz:
        nwi = remap_native_nwi(hra)
        got = fsm_render(nwi, hb)
        if got != g:
            bad += 1
            if first is None: first = (hra, nwi, got, g)
    print("  %s : %s (%d/%d match)" % (label, "ALL MATCH" if bad==0 else "%d BAD"%bad, len(nz)-bad, len(nz)))
    if first:
        hra,nwi,got,g = first
        print("     first bad hra=%#x nwi=%#x got=%010x gold=%010x" % (hra,nwi,got,g))
        print("       got : p4=%02x planes=%08x" % ((got>>32)&0xff, got&0xffffffff))
        print("       gold: p4=%02x planes=%08x" % ((g>>32)&0xff, g&0xffffffff))

# Also report what the COMBINED SIM models (preload = hwswap16(native), FSM hwswap16): should be == golden.
def hwswap16(x): return ((x >> 8) & 0x00FF00FF) | ((x << 8) & 0xFF00FF00)
bad = 0
for hra, g in nz:
    nwi = remap_native_nwi(hra)
    planes = hwswap16(lo_n.get(nwi,0) & 0xFFFFFFFF)
    p4w    = hwswap16(hi_n.get(nwi,0) & 0xFF)
    sw = [planes & 0xFFFF, (planes>>16)&0xFFFF, p4w & 0xFFFF, (p4w>>16)&0xFFFF]
    pw = (sw[1]<<16)|sw[0]; p4word=(sw[3]<<16)|sw[2]
    got = (((hwswap16_32(p4word)&0xff)<<32) | plane_permute(hwswap16_32(pw)))
    if got != g: bad += 1
print("\n  COMBINED-SIM model (preload=hwswap16(native), FSM hwswap16) : %s (%d/%d match)"
      % ("ALL MATCH" if bad==0 else "%d BAD"%bad, len(nz)-bad, len(nz)))
