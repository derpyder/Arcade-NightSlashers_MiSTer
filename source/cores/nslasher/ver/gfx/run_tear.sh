#!/bin/bash
# Reproduce the jtnslasher obj DMA-shadow TEAR (in-game animated-sprite scramble).
# Needs: iverilog/vvp on PATH, python3, the f1800/f2400 OAM caps, the split sprite ROMs.
set -e
export PATH="/c/iverilog/bin:$PATH"
cd "$(dirname "$0")"
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx
CORE=/d/deck/fpga/nightslashers/jtcores/cores/nslasher/hdl
JTF=/d/deck/fpga/nightslashers/jtcores/modules/jtframe/hdl

# 1. build the COMBINED gfx (tiles used by f1800 AND f2400) — only needed once
python3 - <<'PY'
import os
os.chdir(r"/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx")
rom="/path/to/nightslashers/roms"; caps="/path/to/nightslashers/mame-dump/caps"
rd=lambda f: open(os.path.join(rom,f),'rb').read()
def hexf(fr):return[int(l,16)&0xffff for l in open(os.path.join(caps,"f%04d_spr0.hex"%fr)) if l.strip() and l[0] not in '/@']
def l16(r,o,d):
 for i,b in enumerate(d): r[o+i*2]=b
def l32(r,o,d):
 for i,b in enumerate(d): r[o+i*4]=b
g=bytearray(0xa00000)
l16(g,1,rd("mbh-02.14c"));l16(g,0,rd("mbh-04.16c"));l16(g,0x400001,rd("mbh-03.15c"));l16(g,0x400000,rd("mbh-05.17c"));l32(g,0x500000,rd("mbh-06.18c"));l32(g,0x900000,rd("mbh-07.19c"))
XO=[64*8+i for i in range(8)]+[i for i in range(8)];YO=[i*32 for i in range(16)];INC=128*8;BPP=5;po=[(0xa00000//2)*8,16,0,24,8]
def dec(base):
 px=[[0]*16 for _ in range(16)]
 for y in range(16):
  for x in range(16):
   v=0
   for p in range(BPP):
    bit=base+po[p]+YO[y]+XO[x];v|=((g[bit>>3]>>(7-(bit&7)))&1)<<(BPP-1-p)
   px[y][x]=v
 return px
def tw(px,row,half):
 val=0
 for i in range(8):
  v=px[row][half*8+i]
  for p in range(BPP):
   if (v>>p)&1: val|=(1<<(7-i))<<(8*p)
 return val
def used(fr):
 s=set();spr=hexf(fr)
 for o in range(0,0x400,4):
  y=spr[o];c=spr[o+1];m=(1<<((y&0x600)>>9))-1;b=c&~m
  for k in range(m+1):s.add(b+k)
 return s
tiles=sorted(used(1800)|used(2400))
with open("gfx3_combined.hex","w") as f:
 for c in tiles:
  px=dec(c*INC);f.write("@%x\n"%(c*32))
  for row in range(16):
   for half in range(2):f.write("%010x\n"%tw(px,row,half))
print("gfx3_combined.hex: %d tiles"%len(tiles))
PY

# 2. compile + run the tear tb (3 passes: clean A, clean B, TEAR)
iverilog -g2012 -I . -I "$CORE" -o tb_tear.vvp \
  tb_tear.v "$CORE/jtnslasher_obj.v" "$JTF/ram/jtframe_obj_buffer.v" "$JTF/ram/jtframe_dual_ram.v"
vvp tb_tear.vvp

# 3. analyze (pass0==golden, pass2 torn vs pass1)
python3 - <<'PY'
def L(f):return[int(l.strip(),16) for l in open(f) if l.strip()]
g=L("golden_obj.hex");p0=L("tear_pass0.hex");p1=L("tear_pass1.hex");p2=L("tear_pass2.hex")
c=lambda a,b:sum(1 for x,y in zip(a,b) if x!=y)
print("PASS0(clean A) vs golden f1800:",c(p0,g),"diffs (0 == DMA path correct when settled)")
print("PASS2(TEAR) vs PASS1(clean B):",c(p2,p1),"torn px = the in-game scramble")
PY
