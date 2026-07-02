#!/usr/bin/env python3
# Zoom into the PF2 logo text region to see whether the rightmost (T) tiles hold a full letter
# (=> render bug) or are blank/partial (=> the boot drew a partial logo this frame).
import os, zlib, struct
d=os.path.dirname(os.path.abspath(__file__))
def load(n): return [int(l.strip(),16) for l in open(os.path.join(d,n)) if l.strip() and l.strip()[0] not in '/@']
gfx=open(os.path.join(d,"gfx1_tiles16.bin"),'rb').read()
pf2=load("vram_pf2.hex"); PAL=[(w&0xff,(w>>8)&0xff,(w>>16)&0xff) for w in load("vram_pal.hex")]
def scan(c,r): return (c&0x1f)+((r&0x1f)<<5)+((c&0x20)<<5)+((r&0x20)<<6)
def gpix(t,y,x):
    half=1 if x>=8 else 0; i=x&7; o=t*128+(y*2+half)*4
    w=gfx[o]|(gfx[o+1]<<8)|(gfx[o+2]<<16)|(gfx[o+3]<<24); k=7-i
    return ((w>>k)&1)|(((w>>(8+k))&1)<<1)|(((w>>(16+k))&1)<<2)|(((w>>(24+k))&1)<<3)

# print tile numbers for the text rows (cols 32-47) so we see where letters end
print("tile numbers, rows 16-21 cols 30..48 (text region):")
for r in range(16,22):
    print("r%2d:"%r, " ".join("%03x"%(pf2[scan(c,r)]&0xfff) for c in range(30,49)))

# zoomed crop cols 14..50 rows 14..26
C0,C1,R0,R1,Z=14,50,14,26,4
W=(C1-C0)*16; H=(R1-R0)*16
img=[bytearray(W*3) for _ in range(H)]
for r in range(R0,R1):
    for c in range(C0,C1):
        w=pf2[scan(c,r)]; tile=w&0xfff; colour=(w>>12)&0xf; pb=(colour+16)*16
        for y in range(16):
            for x in range(16):
                p=gpix(tile,y,x); idx=pb+p
                R,G,B=(0,0,0) if p==0 else (PAL[idx] if idx<len(PAL) else (255,0,255))
                ox=(c-C0)*16+x; oy=(r-R0)*16+y; o=ox*3; img[oy][o]=R;img[oy][o+1]=G;img[oy][o+2]=B
# zoom
ZW,ZH=W*Z,H*Z
zimg=[bytearray(ZW*3) for _ in range(ZH)]
for y in range(ZH):
    src=img[y//Z]
    for x in range(ZW):
        o=(x//Z)*3; zo=x*3; zimg[y][zo]=src[o];zimg[y][zo+1]=src[o+1];zimg[y][zo+2]=src[o+2]
def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
raw=b''.join(b'\x00'+bytes(x) for x in zimg)
open(os.path.join(d,"zoom_logo.png"),'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",ZW,ZH,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))
print("wrote zoom_logo.png (%dx%d, cols %d-%d rows %d-%d, %dx)"%(ZW,ZH,C0,C1,R0,R1,Z))
