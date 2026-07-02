#!/usr/bin/env python3
# Assemble + decode the Night Slashers sprite gfx (PLAIN, no deco decrypt) to validate the
# scattered-ROM 5bpp assembly before building the sprite engine.
#   gfx3 (0xa00000) 5bpp: mbh-02/04 (LOAD16 odd/even @0) + mbh-03/05 (@0x400000) + mbh-06 (LOAD32 @0x500000) + mbh-07 (LOAD32 @0x900000)
#   gfx4 (0x100000) 4bpp: mbh-08/09 (LOAD16 odd/even @0)
# Layouts (doc/deco32.c): spritelayout_5bpp planes {RGN_FRAC(1,2),16,0,24,8}; spritelayout {16,0,24,8}.
import os, sys, zlib, struct
romdir = sys.argv[1] if len(sys.argv)>1 else "/path/to/nightslashers/roms"
d = os.path.dirname(os.path.abspath(__file__))
rd = lambda f: open(os.path.join(romdir,f),'rb').read()

def load16_byte(region, off, data):           # MAME ROM_LOAD16_BYTE: every other byte from `off`
    for i,b in enumerate(data): region[off+i*2] = b
def load32_byte(region, off, data):           # MAME ROM_LOAD32_BYTE: every 4th byte from `off`
    for i,b in enumerate(data): region[off+i*4] = b

# ---- assemble gfx3 (0xa00000) ----
g3 = bytearray(0xa00000)
load16_byte(g3, 0x000001, rd("mbh-02.14c"))    # 0x200000
load16_byte(g3, 0x000000, rd("mbh-04.16c"))    # 0x200000
load16_byte(g3, 0x400001, rd("mbh-03.15c"))    # 0x080000
load16_byte(g3, 0x400000, rd("mbh-05.17c"))    # 0x080000
load32_byte(g3, 0x500000, rd("mbh-06.18c"))    # 0x100000
load32_byte(g3, 0x900000, rd("mbh-07.19c"))    # 0x040000
# ---- assemble gfx4 (0x100000) ----
g4 = bytearray(0x100000)
load16_byte(g4, 0x000001, rd("mbh-08.16e"))    # 0x080000
load16_byte(g4, 0x000000, rd("mbh-09.18e"))    # 0x080000
print("assembled gfx3=%d bytes gfx4=%d bytes"%(len(g3),len(g4)))

def decode_tile(region, base_bit, planes, planeoff, xoff, yoff):
    px=[[0]*16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            v=0
            for p in range(planes):
                bit=base_bit+planeoff[p]+yoff[y]+xoff[x]
                v|=((region[bit>>3]>>(7-(bit&7)))&1)<<(planes-1-p)
            px[y][x]=v
    return px

XO=[64*8+i for i in range(8)]+[i for i in range(8)]
YO=[i*32 for i in range(16)]
INC=128*8
def lay_sprite(region):  return dict(planes=4, planeoff=[16,0,24,8],                 xoff=XO, yoff=YO, inc=INC, count=(len(region)*8)//INC)
def lay_5bpp(region):    return dict(planes=5, planeoff=[(len(region)//2)*8,16,0,24,8],xoff=XO, yoff=YO, inc=INC, count=((len(region)//2)*8)//INC)

def sheet(path, region, lay, cols, rows, first=0, maxv=15):
    W,H=cols*16,rows*16
    img=[bytearray(W*3) for _ in range(H)]
    for ti in range(cols*rows):
        t=first+ti
        if t>=lay['count']: break
        px=decode_tile(region, t*lay['inc'], lay['planes'], lay['planeoff'], lay['xoff'], lay['yoff'])
        ox,oy=(ti%cols)*16,(ti//cols)*16
        for y in range(16):
            for x in range(16):
                g=px[y][x]*255//maxv; o=(ox+x)*3
                img[oy+y][o]=g; img[oy+y][o+1]=g; img[oy+y][o+2]=g
    def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
    raw=b''.join(b'\x00'+bytes(r) for r in img)
    open(path,'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",W,H,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))
    print("  wrote %s (%dx%d) count=%d"%(path,W,H,lay['count']))

l3=lay_5bpp(g3); l4=lay_sprite(g4)
print("gfx3 5bpp tiles=%d  gfx4 4bpp tiles=%d"%(l3['count'],l4['count']))
sheet(os.path.join(d,"spr_gfx3_5bpp.png"), g3, l3, 32, 32, first=0, maxv=31)
sheet(os.path.join(d,"spr_gfx4_4bpp.png"), g4, l4, 32, 32, first=0, maxv=15)
print("done — eyeball spr_gfx3_5bpp.png / spr_gfx4_4bpp.png for recognizable sprites")
