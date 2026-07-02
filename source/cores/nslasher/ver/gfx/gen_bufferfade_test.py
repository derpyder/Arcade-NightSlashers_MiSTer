#!/usr/bin/env python3
# ============================================================================
# Buffered-palette fade golden — INDEPENDENT from-scratch reimplementation of
# MAME deco_ace::palette_update (deco_ace.cpp:165-199). Written directly from the
# C source, NOT derived from the RTL, to break the self-consistent-golden trap.
#
# MAME palette_update() (the relevant math, deco_ace.cpp):
#   for i in 0..2047:
#       r = buffered[i].r ; g = buffered[i].g ; b = buffered[i].b     # <-- BUFFERED, never live
#       if mode & 0x100:                     # multiplicative fade (mode 0x1100)
#           r = fade_mult(r, fadept.r, fadeps.r) ; ... g,b
#       else:                                # additive fade    (mode 0x1000)
#           r = min(r + fadeps.r, 255) ; ... g,b
#       pens[i]        = rgb(faded r,g,b)    # FADED half  (pens 0..2047)
#       pens[i + 2048] = rgb(buffered r,g,b) # RAW/BUFFERED half (pens 2048..4095) = the snapshot verbatim
#   where fade_mult(c, pt, ps):
#       if pt >= c:  c + ((pt - c) * ps) // 255
#       else:        c - ((c - pt) * ps) // 255
#
# The FADED half is a function of the BUFFERED palette ONLY. Live CPU writes that
# land AFTER the DMA snapshot must NOT affect it until the next DMA. That is the
# property the RTL fix must satisfy and this golden proves.
#
# usage: gen_bufferfade_test.py [dialog|bio]
#   dialog = multiplicative fade toward amber, mode 0x1100  (the near-black dialog pens)
#   bio    = additive +brightness, mode 0x1000              (the smooth bio gradient)
# ============================================================================
import os, sys
d = os.path.dirname(os.path.abspath(__file__))
cfg = sys.argv[1] if len(sys.argv) > 1 else "dialog"

# ---- BUFFERED image B0 (the DMA-frozen snapshot the FSM must fade) -----------
# Idx 0..15   : near-black DIALOG pens (tiny values -> multiplicative fade would
#               bloom them GREEN/toward the target if sourced from the wrong copy).
# Idx 16..271 : a smooth BIO gradient 0..255 per channel (banding shows if drift).
# Everything else: a deterministic spread so all 2048 entries are exercised.
def b0_rgb(i):
    if i < 16:
        # near-black dialog: mostly 0 with a faint blue tint (like dim UI text)
        return (i & 0x3, 0, (i * 2) & 0x7)
    if i < 16 + 256:
        v = i - 16                       # 0..255 smooth ramp
        return (v, (v * 3) & 0xff, 255 - v)
    return (((i * 5) + 7) & 0xff, ((i * 11) + 3) & 0xff, ((i * 19) + 1) & 0xff)

# ---- LIVE image B1 (written mid-next-frame OVER dialog+gradient indices) ------
# Deliberately DIFFERENT from B0 at every index so any drift toward fade(B1) or
# toward the raw B1 value is unmistakable. Dialog indices get bright green here
# (the exact "green dialog pen" repro), the gradient gets inverted.
def b1_rgb(i):
    if i < 16:
        return (0, 255, 0)               # bright GREEN over the dialog pens
    if i < 16 + 256:
        v = i - 16
        return (255 - v, 255 - ((v * 3) & 0xff), v)   # inverted gradient
    return ((~(((i * 5) + 7)) ) & 0xff, (~(((i * 11) + 3))) & 0xff, (~(((i * 19) + 1))) & 0xff)

CFGS = {                                 # (pt=(r,g,b), ps=(r,g,b)), mult
    "dialog": (((255, 160, 0),  (200, 200, 200)), True),   # mult toward amber, mode 0x1100
    "bio":    (((0, 0, 0),      (72, 72, 72)),    False),  # additive +72 (saturating), mode 0x1000
}
(pt, ps), mult = CFGS[cfg]

def fade1(c, pt_c, ps_c):
    if mult:
        if pt_c >= c: return c + ((pt_c - c) * ps_c) // 255
        else:         return c - ((c - pt_c) * ps_c) // 255
    return min(c + ps_c, 255)
def faded(rgb):
    r, g, b = rgb
    return (fade1(r, pt[0], ps[0]), fade1(g, pt[1], ps[1]), fade1(b, pt[2], ps[2]))

B0 = [b0_rgb(i) for i in range(2048)]
B1 = [b1_rgb(i) for i in range(2048)]
GOLD = [faded(c) for c in B0]            # golden faded half = fade(B0), NEVER touches B1

def wr(fn, lst):
    open(os.path.join(d, fn), "w").write(
        "\n".join("%06x" % ((b << 16) | (g << 8) | r) for (r, g, b) in lst) + "\n")

wr("tf_buf.hex",   B0)
wr("tf_live.hex",  B1)
wr("tf_faded.hex", GOLD)

ace_fade = (ps[2] << 40) | (ps[1] << 32) | (ps[0] << 24) | (pt[2] << 16) | (pt[1] << 8) | pt[0]
open(os.path.join(d, "tf_cfg.vh"), "w").write(
    "`define ACE_FADE 48'h%012x\n`define FADE_MULT 1'b%d\n" % (ace_fade, 1 if mult else 0))

# Report discriminating power: how many golden entries would DIFFER if a naive
# (buggy) impl sourced the faded half from live B1 instead of buffered B0.
gold_from_b1 = [faded(c) for c in B1]
ndiff_src   = sum(1 for a, b in zip(GOLD, gold_from_b1) if a != b)
ndiff_faded = sum(1 for a, b in zip(GOLD, B0) if a != b)
print("cfg=%s mult=%s mode=%s" % (cfg, mult, "0x1100" if mult else "0x1000"))
print("  fade(B0) != fade(B1) on %d/2048 entries  (bug-vs-fixed discriminator)" % ndiff_src)
print("  fade(B0) != B0        on %d/2048 entries  (fade is doing real work)" % ndiff_faded)
print("  ace_fade=%012x  fade_mult=%d" % (ace_fade, 1 if mult else 0))
