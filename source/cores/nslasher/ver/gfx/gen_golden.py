#!/usr/bin/env python3
# Generate the GOLDEN 320x240 screen crop the RTL tilemap (jtnslasher_tilemap) must produce:
# the raw pxl = {colour[3:0], pix[3:0]} per screen pixel, for PF2 with the captured scroll.
# Output golden_pxl.hex (row-major sy,sx) for a bit-exact tb compare + golden_crop.png to eyeball.
import os, zlib, struct
d = os.path.dirname(os.path.abspath(__file__))
def load_hex(n): return [int(l.strip(),16) for l in open(os.path.join(d,n)) if l.strip() and l[0] not in '/@']

gfx = open(os.path.join(d,"gfx1_tiles16.bin"),'rb').read()    # reshuffled planar (RTL format)
pf2 = load_hex("vram_pf2.hex")
ctl = load_hex("vram_ctl12.hex")
PAL = [(w&0xff,(w>>8)&0xff,(w>>16)&0xff) for w in load_hex("vram_pal.hex")]
SCRX = ctl[3] & 0x3ff      # PF2 X scroll (map 1024 wide)
SCRY = ctl[4] & 0x1ff      # PF2 Y scroll (map 512 tall)
print("PF2 scroll: x=%d y=%d"%(SCRX,SCRY))

def scan(c,r): return (c&0x1f)+((r&0x1f)<<5)+((c&0x20)<<5)+((r&0x20)<<6)
def gpix(tile,y,x):        # unpack pixel from reshuffled planar gfx
    half=1 if x>=8 else 0; i=x&7
    o=tile*128+(y*2+half)*4
    word=gfx[o]|(gfx[o+1]<<8)|(gfx[o+2]<<16)|(gfx[o+3]<<24)
    k=7-i
    return ((word>>(0+k))&1)|(((word>>(8+k))&1)<<1)|(((word>>(16+k))&1)<<2)|(((word>>(24+k))&1)<<3)

W,Hs=320,240
golden=[]
img=[bytearray(W*3) for _ in range(Hs)]
BG = PAL[0x200] if 0x200<len(PAL) else (0,0,0)
for sy in range(Hs):
    for sx in range(W):
        mapx=(sx+SCRX)&0x3ff; mapy=(sy+SCRY)&0x1ff
        col=mapx>>4; row=mapy>>4; subx=mapx&0xf; suby=mapy&0xf
        w=pf2[scan(col,row)]; tile=w&0xfff; colour=(w>>12)&0xf
        pix=gpix(tile,suby,subx)
        golden.append((colour<<4)|pix)
        idx=(colour+16)*16+pix
        R,G,B = BG if pix==0 else (PAL[idx] if idx<len(PAL) else (255,0,255))
        o=sx*3; img[sy][o]=R; img[sy][o+1]=G; img[sy][o+2]=B

open(os.path.join(d,"golden_pxl.hex"),'w').write('\n'.join("%02x"%v for v in golden)+'\n')
def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
raw=b''.join(b'\x00'+bytes(r) for r in img)
open(os.path.join(d,"golden_crop.png"),'wb').write(
    b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",W,Hs,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))
print("wrote golden_pxl.hex (%d px) + golden_crop.png"%len(golden))
