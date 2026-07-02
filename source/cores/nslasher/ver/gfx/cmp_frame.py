#!/usr/bin/env python3
# Compare the RTL tilemap output (frame_pxl.hex) vs the golden (golden_pxl.hex), bit-exact,
# and render the RTL frame to PNG for eyeballing.
import os, zlib, struct
d = os.path.dirname(os.path.abspath(__file__))
def load(n): return [int(l.strip(),16) for l in open(os.path.join(d,n)) if l.strip() and l.strip()[0] not in '/@']
g = load("golden_pxl.hex"); r = load("frame_pxl.hex")
PAL=[(w&0xff,(w>>8)&0xff,(w>>16)&0xff) for w in load("vram_pal.hex")]
W,H=320,240
n=min(len(g),len(r)); match=sum(1 for i in range(n) if g[i]==r[i])
print("frame compare: %d/%d match (%.2f%%), golden=%d rtl=%d"%(match,n,100.0*match/n,len(g),len(r)))
mm=[i for i in range(n) if g[i]!=r[i]]
if mm:
    print("first mismatches (idx -> sx,sy : golden vs rtl):")
    for i in mm[:12]:
        print("  %5d -> (%3d,%3d) : %02x vs %02x"%(i,i%W,i//W,g[i],r[i]))
# render rtl frame
BG=PAL[0x200] if 0x200<len(PAL) else (0,0,0)
img=[bytearray(W*3) for _ in range(H)]
for i in range(min(len(r),W*H)):
    v=r[i]; colour=(v>>4)&0xf; pix=v&0xf
    idx=(colour+16)*16+pix
    R,G,B = BG if pix==0 else (PAL[idx] if idx<len(PAL) else (255,0,255))
    sx,sy=i%W,i//W; o=sx*3; img[sy][o]=R; img[sy][o+1]=G; img[sy][o+2]=B
def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
raw=b''.join(b'\x00'+bytes(x) for x in img)
open(os.path.join(d,"frame_rtl.png"),'wb').write(
    b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",W,H,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))
print("wrote frame_rtl.png")
