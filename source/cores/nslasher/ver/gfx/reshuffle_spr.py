#!/usr/bin/env python3
# Reshuffle sprite gfx (gfx3 5bpp, gfx4 4bpp) into the RTL fetch layout the obj engine reads:
#   per 16x16 tile: 32 half-rows (16 rows x 2 halves), each = BPP bytes (byte p = plane p,
#   bit7 = leftmost px). word(code,row,half) at half-row index code*32 + row*2 + half.
#   pixel i (0..7) = { word[8*(BPP-1)+7-i], ..., word[7-i] }  (plane BPP-1 = MSB); shift left for next px.
# Only reshuffles the tile range a captured frame actually uses (keeps the .hex small/fast).
#   usage: reshuffle_spr.py [frame=1800]
import os, sys
frame = int(sys.argv[1]) if len(sys.argv)>1 else 1800
d=os.path.dirname(os.path.abspath(__file__)); rom="/path/to/nightslashers/roms"
caps="/path/to/nightslashers/mame-dump/caps"
rd=lambda f: open(os.path.join(rom,f),'rb').read()
def hexf(n): return [int(l,16) for l in open(os.path.join(caps,"f%04d_%s.hex"%(frame,n))) if l.strip() and l[0] not in '/@']
def l16(reg,off,data):
    for i,b in enumerate(data): reg[off+i*2]=b
def l32(reg,off,data):
    for i,b in enumerate(data): reg[off+i*4]=b
g3=bytearray(0xa00000); l16(g3,1,rd("mbh-02.14c")); l16(g3,0,rd("mbh-04.16c")); l16(g3,0x400001,rd("mbh-03.15c")); l16(g3,0x400000,rd("mbh-05.17c")); l32(g3,0x500000,rd("mbh-06.18c")); l32(g3,0x900000,rd("mbh-07.19c"))
g4=bytearray(0x100000); l16(g4,1,rd("mbh-08.16e")); l16(g4,0,rd("mbh-09.18e"))
XO=[64*8+i for i in range(8)]+[i for i in range(8)]; YO=[i*32 for i in range(16)]; INC=128*8
SET={3:(g3,5,[(0xa00000//2)*8,16,0,24,8],"gfx3_spr"),4:(g4,4,[16,0,24,8],"gfx4_spr")}

def used_tiles(name):
    spr=hexf(name); s=set()
    for offs in range(0,0x400,4):
        y=spr[offs]&0xffff; code=spr[offs+1]&0xffff; multi=(1<<((y&0x600)>>9))-1
        base=code & ~multi
        for k in range(multi+1): s.add(base+k)
    return sorted(s)

def decode_tile(reg,planes,po,base):
    px=[[0]*16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            v=0
            for p in range(planes):
                bit=base+po[p]+YO[y]+XO[x]; v|=((reg[bit>>3]>>(7-(bit&7)))&1)<<(planes-1-p)
            px[y][x]=v
    return px

def tileword(px,row,half,bpp):                 # -> packed BPP-byte planar value (plane0=LSB byte)
    val=0
    for i in range(8):
        v=px[row][half*8+i]
        for p in range(bpp):
            if (v>>p)&1: val |= (1<<(7-i)) << (8*p)
    return val

for bank,(reg,bpp,po,name) in SET.items():
    tiles=used_tiles({3:"spr0",4:"spr1"}[bank]); digits=bpp*2
    maxaddr=(max(tiles)*32 + 31) if tiles else 0
    with open(os.path.join(d,name+".hex"),'w') as f:    # sparse @addr blocks (only used tiles)
        for code in tiles:
            px=decode_tile(reg,bpp,po,code*INC)
            f.write("@%x\n"%(code*32))
            for row in range(16):
                for half in range(2):
                    f.write(("%0"+str(digits)+"x\n")%tileword(px,row,half,bpp))
    print("%s: %d used tiles (bpp=%d, max code=%#x) -> %s.hex  mem size=%d words (%d-bit)"%(
          name,len(tiles),bpp,max(tiles) if tiles else 0,name,maxaddr+1,bpp*8))
