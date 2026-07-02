#!/usr/bin/env python3
# FIX C2 / task #9 gate: synthetic per-tile FLIP + colour&7 golden for jtnslasher_tilemap.
# MAME semantics (doc/mame_deco16ic.c get_pfN_tile_info:248-345): when the layer's ctl[6]
# flip-enable bit is set AND tile bit15 is set -> flip that axis AND colour &= 7.
# The golden is derived from THOSE source semantics + the reshuffle_gfx layout spec — NOT from the
# RTL (no self-consistent-test trap): pen(code,y,x) is an asymmetric analytic pattern, the screen
# mapping is the gen_layer.py mapping (bit-exact-validated at M3f), flips/masks per the C code above.
#   usage: gen_flip_test.py <tile8 0|1> <flip_en 0-3>
# Emits ft_pf.hex / ft_gfx.hex / ft_golden.hex / flip_cfg.vh for tb_flip.v.
import os, sys

tile8   = int(sys.argv[1])
flip_en = int(sys.argv[2])           # bit0 = FLIPX enable, bit1 = FLIPY enable
d = os.path.dirname(os.path.abspath(__file__))

SIZE = 8 if tile8 else 16
SCRX, SCRY = 5, 3                    # sub-tile offsets exercised
NCODE = 64

def pen(code, y, x):                 # asymmetric: distinguishes every flip combination
    return (x + 3*y + code) & 0xF

# ---- VRAM: 2048 words. tile = bit15 varied | colour (incl >=8) | code ----
vram = []
for idx in range(2048):
    row, col = idx >> 6, idx & 0x3f            # layout irrelevant; scan formula picks words
    code   = (row*7 + col) & (NCODE-1)
    colour = (row + col) & 0xf
    b15    = (row ^ col) & 1
    vram.append((b15 << 15) | (colour << 12) | code)

# ---- gfx ROM in the reshuffled planar layout ----
# 16x16: word addr = code*32 + y*2 + half (half0 = x0-7, half1 = x8-15)
#  8x8 : word addr = code*8 + y
# byte p, bit (7-j) = pen bit p of pixel j (j = x within the half, 0 = leftmost)
nwords = NCODE * (8 if tile8 else 32)
gfx = [0]*nwords
for code in range(NCODE):
    for y in range(SIZE):
        for half in range(1 if tile8 else 2):
            w = 0
            for j in range(8):
                v = pen(code, y, half*8 + j)
                for p in range(4):
                    if (v >> p) & 1: w |= 1 << (8*p + (7-j))
            gfx[(code*8 + y) if tile8 else (code*32 + y*2 + half)] = w

# ---- golden: 320x240 {colour,pix} stream per the MAME flip semantics ----
MX = 0x1ff if tile8 else 0x3ff
MY = 0x0ff if tile8 else 0x1ff
SH = 3 if tile8 else 4
gold = []
for sy in range(240):
    for sx in range(320):
        mapx = (sx + SCRX) & MX; mapy = (sy + SCRY) & MY
        col = mapx >> SH; row = mapy >> SH
        subx = mapx & (SIZE-1); suby = mapy & (SIZE-1)
        if tile8: scan = ((row & 0x1f) << 6) | (col & 0x3f)
        else:     scan = (col & 0x1f) + ((row & 0x1f) << 5) + ((col & 0x20) << 5) + ((row & 0x20) << 6)
        w = vram[scan]
        code = w & 0xfff; colour = (w >> 12) & 0xf; b15 = (w >> 15) & 1
        fx = b15 and (flip_en & 1); fy = b15 and (flip_en & 2)
        if b15 and (flip_en & 3): colour &= 7
        ex = (SIZE-1) - subx if fx else subx
        ey = (SIZE-1) - suby if fy else suby
        gold.append((colour << 4) | pen(code & (NCODE-1), ey, ex))

open(os.path.join(d,"ft_pf.hex"),"w").write("\n".join("0000%04x" % w for w in vram)+"\n")
open(os.path.join(d,"ft_gfx.hex"),"w").write("\n".join("%08x" % w for w in gfx)+"\n")
open(os.path.join(d,"ft_golden.hex"),"w").write("\n".join("%02x" % b for b in gold)+"\n")
open(os.path.join(d,"flip_cfg.vh"),"w").write(
    "`define TILE8 1'd%d\n`define FLIPEN 2'd%d\n`define SCRX 10'd%d\n`define SCRY 9'd%d\n" % (tile8, flip_en, SCRX, SCRY))
print("flip test: tile8=%d flip_en=%d  vram=2048 gfx=%d words  golden=76800" % (tile8, flip_en, nwords))
