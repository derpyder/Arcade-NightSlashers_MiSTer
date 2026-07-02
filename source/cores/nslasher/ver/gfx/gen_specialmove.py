#!/usr/bin/env python3
# Synthesize a SPECIAL-MOVE (screen-filling effect) sprite frame: max sprite density.
# Night Slashers special moves spray large multi-tile effect sprites that blanket the
# playfield. We approximate the worst case: fill the 256-entry sprite table with sprites
# whose vertical zones all overlap a band of scanlines, so many sprites are active on the
# same line (driving line_cnt toward the 127 cap and the per-line fetch budget).
#
# Format: ffffDDDD words, 4 words/sprite (y, code, x, attr) — matches tb_obj_f2700_lat's
# sprtbl[...] [15:0] consumption + gen_obj_golden expectations.
# Writes f8888_spr0.hex / f8888_spr1.hex in caps/, and a matching obj_cfg_f8888.vh + gfx file
# reuse (we reuse gfx3_f2700.hex as the tile data; correctness already proven, this is a
# BANDWIDTH/overflow test, not a data test).
import os, sys
caps="/path/to/nightslashers/mame-dump/caps"
gfxdir="/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx"

# number of sprites all overlapping the test band (default = full table 255)
n      = int(sys.argv[1]) if len(sys.argv)>1 else 255
# msz: multi-tile size. Special-move FX sprites are large (e.g. 4x4=msz tall). Bigger msz =>
# the sprite spans more scanlines => present on more lines => more fetches/line.
msz    = int(sys.argv[2]) if len(sys.argv)>2 else 0     # 0 = single 16x16 tile (1 tile tall)
CODE   = 0x4acb   # a real reshuffled tile

words=[0xffff0000]*2048
band_y = 100      # all sprites centred on the same scanline band
for i in range(min(n,255)):
    off=i*4
    words[off+0]=0xffff0000|(band_y & 0x1ff)|((msz&0x7)<<9 if False else 0)  # y in low bits
    words[off+1]=0xffff0000|CODE
    x = (i*5) % 320                  # spread horizontally across the line
    words[off+2]=0xffff0000|(x & 0x1ff)
    # attr word: keep size single-tile (msz handled by RTL bits we don't set here -> 1 tile)
    words[off+3]=0xffff0000
open(os.path.join(caps,"f8888_spr0.hex"),'w').write('\n'.join("%08x"%w for w in words)+'\n')
open(os.path.join(caps,"f8888_spr1.hex"),'w').write('\n'.join("ffff0000" for _ in range(2048))+'\n')

# cfg: reuse f2700 gfx + BPP/MEMW
cfg = open(os.path.join(gfxdir,"obj_cfg_f2700.vh")).read()
cfg = cfg.replace("f2700_spr0.hex","f8888_spr0.hex")
open(os.path.join(gfxdir,"obj_cfg_f8888.vh"),'w').write(cfg)
print("wrote f8888 special-move: %d sprites all on line %d (code %#x)"%(min(n,255),band_y,CODE))
