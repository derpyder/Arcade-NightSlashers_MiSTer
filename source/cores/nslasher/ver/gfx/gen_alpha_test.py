#!/usr/bin/env python3
# Build A verification: constructed ACE-active sweep for jtnslasher_colmix's deco_ace get_alpha blend.
# Faithful port of MAME deco_ace.cpp:208-224 (get_alpha) + deco32_v.cpp:390 (alpha gate) +
# alpha_blend_r32 = (s*a + d*(256-a))>>8 (with a==0xFF routed as opaque replace, a documented <=1-LSB
# simplification). Emits per-vector inputs + the NEW golden (correct) and the OLD golden (fixed 50%,
# = the unmodified colmix) so one tb run proves BOTH correctness (==NEW) and discrimination (!=OLD).
import os
d = os.path.dirname(os.path.abspath(__file__))

# ---- synthetic palette: 2048 distinct pens (R,G,B) ----
def pal_rgb(i):
    return (((i*5)+7) & 0xff, ((i*11)+3) & 0xff, ((i*19)+1) & 0xff)
PAL = [pal_rgb(i) for i in range(2048)]

# ---- MAME deco_ace.cpp:208-224 get_alpha (index already < 0x06 here) ----
def get_alpha(ace_byte):
    a = ace_byte & 0xff
    if a > 0x20:
        return 0x80
    a = 255 - (a << 3)
    return 0 if a < 0 else a

# ---- MAME alpha_blend_r32 channel: (s*a + d*(256-a))>>8 ----
def blend8(d, s, a):
    return (s*a + d*(256-a)) >> 8

def composite(pf2_pxl, obj1_pxl, ace6, model):
    # bg stack (pf1=pf3=pf4=0, pri=0): front=pf2 -> bgpen
    pf2on = (pf2_pxl & 0x0f) != 0
    bgpen = (0x100 | pf2_pxl) if pf2on else 0x200
    underpen = bgpen                       # obj0 = 0 -> underpen = bgpen
    # obj1
    o1on  = (obj1_pxl & 0xff) != 0
    p1    = (obj1_pxl >> 13) & 3
    o1a   = (obj1_pxl >> 15) & 1
    o1col = (obj1_pxl >> 8) & 0xf
    o1pen = 0x600 | (o1col << 4) | (obj1_pxl & 0xf)
    over0 = True                           # o0on=0
    o1op = o1on and (not o1a) and ( (p1==0 and over0) or p1==1 or p1==2 or p1==3 )
    o1ad = o1on and o1a       and ( (p1==0 and over0) or (p1==1 and over0) or p1==2 or p1==3 )
    o1_draw = o1op or o1ad
    if model == "OLD":
        # unmodified colmix: o1op opaque replace, o1ad fixed 50%
        if o1op:
            portA = o1pen
            return PAL[portA]
        if o1ad:
            d = PAL[underpen]; s = PAL[o1pen]
            return tuple((dc+sc) >> 1 for dc, sc in zip(d, s))
        return PAL[underpen]
    # NEW (deco_ace get_alpha)
    aidx = (4 + ((o1col >> 1) & 1)) if (o1col & 8) else ((o1col >> 1) & 3)
    a_lut = get_alpha(ace6[aidx])
    bit12 = (obj1_pxl >> 12) & 1
    agate = (not o1a) or (not bit12)
    alpha_eff = a_lut if agate else 0xFF
    if not o1_draw:
        return PAL[underpen]
    if alpha_eff == 0xFF:
        return PAL[o1pen]                  # opaque replace
    if alpha_eff == 0:
        return PAL[underpen]               # fully transparent
    d = PAL[underpen]; s = PAL[o1pen]
    return tuple(blend8(dc, sc, alpha_eff) for dc, sc in zip(d, s))

# ---- constructed sweep ----
UNDERS = [0x11, 0x25, 0x3a, 0x07, 0x52]                 # pf2_pxl -> 5 under pens
ACEVALS = [0x00, 0x08, 0x10, 0x18, 0x1f, 0x20, 0x21, 0x40]  # get_alpha -> 255,191,127,63,7,0,0x80,0x80
COLS   = [0x0, 0x2, 0x4, 0x8, 0xa]                      # -> aidx 0,1,2,4,5
ALPHA1 = [0, 1]                                          # bit15
BIT12  = [0, 1]                                          # alpha2 = ~bit12
PEN    = 0x5
P1     = 2                                               # guarantees o1_draw fires

vecs = []   # (pf1,pf2,pf3,pf4, obj0, obj1, ace48)
for under in UNDERS:
    for a1 in ALPHA1:
        for b12 in BIT12:
            for col in COLS:
                for av in ACEVALS:
                    obj1 = (a1<<15) | (P1<<13) | (b12<<12) | (col<<8) | PEN
                    aidx = (4 + ((col >> 1) & 1)) if (col & 8) else ((col >> 1) & 3)
                    ace6 = [0]*6
                    ace6[aidx] = av
                    ace48 = 0
                    for k in range(6):
                        ace48 |= (ace6[k] & 0xff) << (8*k)
                    vecs.append((0, under, 0, 0, 0, obj1, ace6, ace48))

N = len(vecs)
def w(fn, fmt, idx):
    open(os.path.join(d, fn), "w").write("\n".join(fmt % v[idx] for v in vecs) + "\n")
w("ta_pf1.hex", "%02x", 0); w("ta_pf2.hex", "%02x", 1)
w("ta_pf3.hex", "%02x", 2); w("ta_pf4.hex", "%02x", 3)
w("ta_obj0.hex", "%04x", 4); w("ta_obj1.hex", "%04x", 5)
open(os.path.join(d, "ta_ace.hex"), "w").write("\n".join("%012x" % v[7] for v in vecs) + "\n")
open(os.path.join(d, "ta_pal.hex"), "w").write(
    "\n".join("%06x" % ((PAL[i][2]<<16)|(PAL[i][1]<<8)|PAL[i][0]) for i in range(2048)) + "\n")

def golden(model):
    out = []
    for (pf1,pf2,pf3,pf4,o0,o1,ace6,ace48) in vecs:
        r,g,b = composite(pf2, o1, ace6, model)
        out.append("%06x" % ((b<<16)|(g<<8)|r))   # {blue,green,red} to match colmix.v:109-111
    return out
new = golden("NEW"); old = golden("OLD")
open(os.path.join(d, "ta_golden.hex"), "w").write("\n".join(new)+"\n")
open(os.path.join(d, "ta_golden_old.hex"), "w").write("\n".join(old)+"\n")
ndiff = sum(1 for a,b in zip(new,old) if a!=b)
print("vectors=%d  NEW!=OLD on %d (%.1f%%) -> falsifiability set"%(N, ndiff, 100.0*ndiff/N))
print("wrote ta_{pf1-4,obj0-1,ace,pal,golden,golden_old}.hex")
