#!/usr/bin/env python3
# Synthesize a sprite table that places >40 single-tile sprites on ONE scanline (y=100), to test
# whether the RTL's line_cnt>=40 per-line cap drops tiles vs MAME (which has no cap). Writes a cap
# file in the same ffffDDDD format the tb + gen_obj_golden expect.
# usage: gen_synth_cap.py <ntiles> -> f9999_spr0.hex  (uses real code 0x9bef = a known tile)
import os, sys
caps="/path/to/nightslashers/mame-dump/caps"
n=int(sys.argv[1]) if len(sys.argv)>1 else 50
CODE=0x4acb  # a real tile from f1800 spr0 (in the reshuffled gfx range)
words=[0xffff0000]*2048
for i in range(min(n,255)):
    off=i*4
    # word0: y=100, msz=0, no flip bits set in our decode sense (fx/fy raw=0 -> pixel flip=1)
    y=100
    words[off+0]=0xffff0000|(y&0x1ff)
    words[off+1]=0xffff0000|CODE
    x=8+i*1  # cluster them on screen near x=8.. (overlapping, all on line 100)
    if x>319: x=319
    words[off+2]=0xffff0000|(x&0x1ff)
    words[off+3]=0xffff0000
open(os.path.join(caps,"f9999_spr0.hex"),'w').write('\n'.join("%08x"%w for w in words)+'\n')
# spr1 empty (so reshuffle for spr1 has nothing) -> just copy a zero table
open(os.path.join(caps,"f9999_spr1.hex"),'w').write('\n'.join("ffff0000" for _ in range(2048))+'\n')
print("wrote f9999 with %d single-tile sprites on line 100 (code %#x)"%(n,CODE))
