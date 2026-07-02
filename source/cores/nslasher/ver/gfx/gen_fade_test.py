#!/usr/bin/env python3
# Build B fade-FSM verification: generate a raw palette + the verbatim-C deco_ace fade golden
# (deco_ace.cpp:188-195) for a chosen config. usage: gen_fade_test.py [amber|black|add]
import os, sys
d = os.path.dirname(os.path.abspath(__file__))
cfg = sys.argv[1] if len(sys.argv) > 1 else "amber"

def raw_rgb(i): return (((i*5)+7) & 0xff, ((i*11)+3) & 0xff, ((i*19)+1) & 0xff)
RAW = [raw_rgb(i) for i in range(2048)]

CFGS = {                       # (pt=(r,g,b), ps=(r,g,b)), mult
    "black": ((( 0,  0,  0), (255,255,255)), True),    # fade to black (the f1800 case)
    "amber": (((255,128,  0), (128,128,128)), True),   # partial fade to amber
    "add":   ((( 0,  0,  0), ( 64, 64, 64)),  False),  # additive +64 (saturating)
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

F = [faded(c) for c in RAW]
def wr(fn, lst):
    open(os.path.join(d, fn), "w").write("\n".join("%06x" % ((b<<16)|(g<<8)|r) for (r,g,b) in lst) + "\n")
wr("tf_raw.hex", RAW); wr("tf_faded.hex", F)
ace_fade = (ps[2]<<40)|(ps[1]<<32)|(ps[0]<<24)|(pt[2]<<16)|(pt[1]<<8)|pt[0]
open(os.path.join(d, "tf_cfg.vh"), "w").write(
    "`define ACE_FADE 48'h%012x\n`define FADE_MULT 1'b%d\n" % (ace_fade, 1 if mult else 0))
ndiff = sum(1 for a, b in zip(RAW, F) if a != b)
print("cfg=%s mult=%s  faded!=raw on %d/2048 (discriminating); ace_fade=%012x" % (cfg, mult, ndiff, ace_fade))
