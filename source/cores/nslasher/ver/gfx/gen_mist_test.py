#!/usr/bin/env python3
# Build C alpha-tilemap (mist) + obj1-alpha verification — FIX C model (2026-07-02).
# Golden (mame=True) = the 0284 mix_nslasher semantics for the colmix subset (pf4=0 except joint,
# raw==faded single palette). Sources: deco32_v.cpp mix_nslasher:339-459 + screen_update:463-521,
# deco32.cpp mix_callback:936-939. FIX C changes encoded here (each vs the pre-FIX-C golden):
#   1. mist pen = pri0 ? (TMB0<<8)|frontpf : 0x100|frontpf  — p is the front-PF PIXMAP value
#      (includes the tilemap colour bank; pal2 colorbase()==0 for BOTH gfx in 0284). The old
#      0x000/0x200 pal2 bases were 2009-driver descent; tm_bank0 is boot-static =2 (attract_pri.txt
#      complete write log) so the foliage-vs-special-move conflict is arbitrated to THIS formula.
#   2. mist never fires on PF1 pixels (MAME mixes the alpha tilemap BEFORE drawing PF1, :517-519).
#   3. obj1 ALPHA pri1 0/1 tilemap-side suppression terms (:410-418) incl. the alphaTilemap-pen==0
#      exception and the pri0==2 relaxation for pri1==1 when (m_pri&1)==0.
#   4. pri&2 = JOINT-8bpp path (:491-495): combined PF3/4 stack, NO mist; obj0-pri2 on-top uses the
#      raw mixAlphaTilemap flag in both modes.
# Old/wrong (mame=False) = the pre-FIX-C model (nf14-era pen + no suppression + mist at pri&2),
# kept only so the test proves the formulas differ (discrimination gate).
import os
d = os.path.dirname(os.path.abspath(__file__))

def pal_rgb(i): return (((i*5)+7) & 0xff, ((i*11)+3) & 0xff, ((i*19)+1) & 0xff)
def pal_fad(i): return (((i*7)+11) & 0xff, ((i*13)+5) & 0xff, ((i*3)+9) & 0xff)
PALR = [pal_rgb(i) for i in range(2048)]           # RAW half (deco_ace pens 0x800+)
PALF = [pal_fad(i) for i in range(2048)]           # FADED half (pens 0-0x7ff) — DISTINCT so the
                                                    # raw/faded coloffs selects are discriminated

def get_alpha(v):
    v &= 0xff
    if v > 0x20: return 0x80
    a = 255 - (v << 3); return 0 if a < 0 else a
def blend8(d, s, a): return (s*a + d*(256-a)) >> 8

TMB0, TMB1 = 2, 3            # runtime tilemap colour banks (0x164000) — boot-static in nslasher

# ---- MAME-faithful mini mix_nslasher (stack + obj0 + obj1 + mist + pf1; pri[2]=0=raw) ----
def composite(pf1, pf2, pf3, obj0, obj1, pri, ace8, aob8, mame=True):
    pri0 = pri & 1
    alpha_flag = (ace8[0] != 0) and ((pri & 3) != 0)      # mixAlphaTilemap: ace[0x17]!=0 && (m_pri&3)
    joint = mame and (pri & 2)                            # 0284: pri&2 -> JOINT path, no alpha bitmap
    alpha_mist_en = alpha_flag and ((not (pri & 2)) if mame else True)
    frontpf  = pf3 if pri0 else pf2
    front_on = (frontpf & 0x0f) != 0
    front_pen = (0x200 | pf3) if pri0 else (0x100 | pf2)
    midpf    = pf2 if pri0 else pf3
    mid_on   = (midpf & 0x0f) != 0
    mid_pen  = (0x100 | pf2) if pri0 else (0x200 | pf3)
    # ---- bg stack ----
    bgpen = 0x300; tpri = 0
    if joint:
        # JOINT-8bpp (deco32_v.cpp:493-494): combined PF3/4 (pf4=0 in this harness) under PF2
        p = (TMB0 << 8) | pf3; p2 = (TMB1 << 8) | 0
        jpen = ((p & 0x70f) + (((p & 0x30) | (p2 & 0x0f)) << 4)) & 0x7ff
        if jpen & 0xff: bgpen = jpen; tpri |= 1
        if pf2 & 0x0f:  bgpen = 0x100 | pf2; tpri |= 4
    else:
        if mid_on:   bgpen = mid_pen; tpri |= 2
        if front_on:
            if not alpha_mist_en: bgpen = front_pen
            tpri |= 4
    # ---- obj0 ----
    o0on = (obj0 & 0xff) != 0
    p0v  = (obj0 >> 13) & 3
    col0 = (obj0 >> 8) & 0xf
    o0pen = 0x400 | (col0 << 5) | (obj0 & 0x1f)
    if p0v in (0, 1):  o0draw = o0on
    elif p0v == 2:     o0draw = o0on and ((alpha_flag if mame else False) or (tpri < 4))  # F3 + joint raw flag
    else:              o0draw = o0on and (tpri < 2)
    # coloffs model (pri[2]=0 in all vectors): PF/backdrop=FADED, obj0=RAW,
    # obj1 & mist-src = RAW iff obj0 drew (sprite1_drawn) else FADED, PF1 = RAW (0284) / FADED (old)
    dest = PALR[o0pen] if o0draw else PALF[bgpen]
    # ---- obj1 (deco32_v.cpp:386-440) ----
    o1on = (obj1 & 0xff) != 0
    p1v  = (obj1 >> 13) & 3
    col1 = (obj1 >> 8) & 0xf
    o1a  = (obj1 >> 15) & 1
    alpha2 = not ((obj1 >> 12) & 1)
    o1pen = 0x600 | (col1 << 4) | (obj1 & 0xf)
    aidx = (4 + ((col1 & 3) // 2)) if (col1 & 8) else ((col1 & 7) // 2)
    a_eff = get_alpha(aob8[aidx]) if ((not o1a) or alpha2) else 0xff
    if o1on:
        over0   = (not o0on) or p0v == 3
        if o1a:
            if mame:
                alpha_empty = bool(joint) or not front_on          # (alphaTilemap[x]&0xf)==0
                o1p0_tm  = (not pri0) or (not (tpri & 4)) or (alpha_flag and alpha_empty)
                o1p1_tm  = (not pri0) or (not (tpri & 4))
                over0p1  = (not o0on) or p0v == 3 or (p0v == 2 and not pri0)
            else:
                o1p0_tm = o1p1_tm = True; over0p1 = over0          # pre-FIX-C: no suppression
            o1draw = (p1v == 0 and over0 and o1p0_tm) or (p1v == 1 and over0p1 and o1p1_tm) \
                     or p1v in (2, 3)
        else:
            o1draw = (p1v == 0 and ((not o0on) or p0v != 0)) or p1v in (1, 2, 3)
        if o1draw:
            P1 = PALR if o0draw else PALF                       # selB = ~pri2 & o0draw
            if a_eff == 0xff:   dest = P1[o1pen]
            elif a_eff != 0:    dest = tuple(blend8(dest[k], P1[o1pen][k], a_eff) for k in range(3))
    # ---- alpha-tilemap mist (deco32_v.cpp:442-458) ----
    mist_g0 = (not o0on) or p0v == 2 or p0v == 3
    mist_g1 = (not o1on) or p1v == 2 or p1v == 3 or bool(o1a)
    pf1_on  = (pf1 & 0x0f) != 0
    mist_draw = alpha_mist_en and front_on and mist_g0 and mist_g1 and ((not pf1_on) if mame else True)
    if mist_draw:
        if mame:
            mist_pen = ((TMB0 << 8) | frontpf) if pri0 else (0x100 | frontpf)   # FIX C formula
        else:
            mist_pen = (0x000 | frontpf) if pri0 else (0x200 | frontpf)         # pre-FIX-C (nf18)
        tile_off   = (frontpf >> 5) & 0x7
        mist_alpha = get_alpha(ace8[tile_off])
        PM = PALR if o0draw else PALF                           # selC = ~pri2 & o0draw
        dest = tuple(blend8(dest[k], PM[mist_pen][k], mist_alpha) for k in range(3))
    # ---- PF1 text last (deco32_v.cpp:519); 0284 chars colorbase 0x800 = RAW half, never faded ----
    if pf1_on:
        dest = (PALR if mame else PALF)[pf1 & 0xff]
    return dest

# ---- vectors: pri x scene x mist colour x ace value x obj0 x obj1 x pf1 x obj-alpha ----
ACE17  = 0x10
SCENES = [0x25, 0x3a, 0x52]      # mid PF pixel
MISTS  = [0x4, 0x8, 0xc]         # front PF colour nibble (-> tile_off = nibble>>1 = 2,4,6)
ACEV   = [0x00, 0x08, 0x10, 0x20]
PIXS   = [0x5, 0x0]              # front pen present / TRANSPARENT (alpha_empty exception coverage)
PRIS   = [0b001, 0b000, 0b011, 0b010]   # bit0=front sel, bit1=8bpp join
OBJS   = [0x0000,                       # no obj0
          (2 << 13) | (3 << 8) | 0x12,  # obj0 pri2, col3 — under-mist (F3) case
          (0 << 13) | (1 << 8) | 0x07]  # obj0 pri0 (on top, mist suppressed where it covers)
OBJ1S  = [0x0000,                       # no obj1
          0x8103,                       # alpha1 pri0 col1 pen3
          0xA103,                       # alpha1 pri1
          0xC103,                       # alpha1 pri2 (unconditional TODO branch)
          0x9103,                       # alpha1 pri0 + bit12 (alpha2=0 -> forced opaque 0xff)
          0x0103]                       # non-alpha pri0
PF1S   = [0x00, 0x21]                   # text off / on (colour 2, pen 1)
AOBS   = [0x00, 0x10]                   # obj-alpha ace byte: FF opaque / 127 blend

vecs = []
for pr in PRIS:
  for PIX in PIXS:
    for sc in SCENES:
        for mc in MISTS:
            for av in ACEV:
                for ob in OBJS:
                    for o1 in OBJ1S:
                        for p1 in PF1S:
                            for ao in AOBS:
                                pf2 = sc if (pr & 1) else ((mc << 4) | PIX)
                                pf3 = ((mc << 4) | PIX) if (pr & 1) else sc
                                off = mc >> 1
                                ace8 = [0]*8; ace8[0] = ACE17; ace8[off] = av
                                ace64 = 0
                                for k in range(8): ace64 |= (ace8[k] & 0xff) << (8*k)
                                aob8 = [ao]*6
                                aob48 = 0
                                for k in range(6): aob48 |= (ao & 0xff) << (8*k)
                                new = composite(p1, pf2, pf3, ob, o1, pr, ace8, aob8, mame=True)
                                old = composite(p1, pf2, pf3, ob, o1, pr, ace8, aob8, mame=False)
                                vecs.append((pf2, pf3, ob, o1, p1, pr, ace64, aob48, new, old))

N = len(vecs)
w = lambda nm, fn: open(os.path.join(d, nm), "w").write("\n".join(fn(v) for v in vecs) + "\n")
w("tm_pf2.hex",    lambda v: "%02x" % v[0])
w("tm_pf3.hex",    lambda v: "%02x" % v[1])
w("tm_obj0.hex",   lambda v: "%04x" % v[2])
w("tm_obj1.hex",   lambda v: "%04x" % v[3])
w("tm_pf1.hex",    lambda v: "%02x" % v[4])
w("tm_pri.hex",    lambda v: "%x"   % v[5])
w("tm_ace.hex",    lambda v: "%016x" % v[6])
w("tm_aob.hex",    lambda v: "%012x" % v[7])
open(os.path.join(d, "tm_palr.hex"), "w").write(
    "\n".join("%06x" % ((PALR[k][2]<<16)|(PALR[k][1]<<8)|PALR[k][0]) for k in range(2048)) + "\n")
open(os.path.join(d, "tm_palf.hex"), "w").write(
    "\n".join("%06x" % ((PALF[k][2]<<16)|(PALF[k][1]<<8)|PALF[k][0]) for k in range(2048)) + "\n")
rgb = lambda t: "%06x" % ((t[2]<<16)|(t[1]<<8)|t[0])
w("tm_golden.hex",     lambda v: rgb(v[8]))
w("tm_golden_old.hex", lambda v: rgb(v[9]))
open(os.path.join(d, "tm_cfg.vh"), "w").write("`define TMN %d\n" % N)
ndiff = sum(1 for v in vecs if v[8] != v[9])
print("mist vectors=%d  NEW!=OLD on %d (%.0f%%) -> discriminating (FIX C: pen formula + pf1 gate + obj1 suppression + joint)" % (N, ndiff, 100.0*ndiff/N))
