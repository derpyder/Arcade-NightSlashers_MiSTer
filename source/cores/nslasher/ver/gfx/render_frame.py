#!/usr/bin/env python3
# M3b — render the boot's captured frame offline (first pass: PF2 tilemap + palette).
# Uses the decrypted gfx1 (gfx1_dec.bin from decode_gfx.py) + the captured VRAM (vram_*.hex).
#
# PF2 (the only active layer in this frame): gfx[1]=gfx1 16x16 tilelayout, map 64x32 via
# deco16_scan_rows, tile=(w&0xfff)|bank(0), colour=(w>>12)&0xf, palette idx=(colour+16)*16+pixel.
import os, zlib, struct
d = os.path.dirname(os.path.abspath(__file__))

def load_hex(name):
    return [int(l.strip(),16) for l in open(os.path.join(d,name)) if l.strip() and l[0] not in '/@']
def write_png(path, w, h, rows):
    def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
    raw=b''.join(b'\x00'+bytes(r) for r in rows)
    open(path,'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",w,h,8,2,0,0,0))+
                          ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))

gfx1 = open(os.path.join(d,"gfx1_dec.bin"),'rb').read()
HALF = len(gfx1)*8//2                        # RGN_FRAC(1,2)
PO   = [HALF+8, HALF, 8, 0]                  # tilelayout planeoffset (MSB..LSB)
XO   = [32*8+i for i in range(8)] + [i for i in range(8)]
YO   = [i*16 for i in range(16)]
INC  = 64*8

def tile16(t):                               # -> 16x16 list of 4bpp values
    base=t*INC; out=[[0]*16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            v=0
            for p in range(4):
                bit=base+PO[p]+YO[y]+XO[x]
                v|=((gfx1[bit>>3]>>(7-(bit&7)))&1)<<(3-p)
            out[y][x]=v
    return out

pal_raw = load_hex("vram_pal.hex")
PAL = [( w&0xff, (w>>8)&0xff, (w>>16)&0xff ) for w in pal_raw]   # 0x00BBGGRR -> (R,G,B)
def pen(idx): return PAL[idx] if idx < len(PAL) else (255,0,255)

pf2 = load_hex("vram_pf2.hex")
def scan(col,row): return (col&0x1f) + ((row&0x1f)<<5) + ((col&0x20)<<5) + ((row&0x20)<<6)

# ---- full PF2 map, 64x32 tiles = 1024x512, every pixel through the palette ----
W,H = 64*16, 32*16
img=[bytearray(W*3) for _ in range(H)]
cache={}
nz=0
for row in range(32):
    for col in range(64):
        w = pf2[scan(col,row)]
        tile=(w&0xfff); colour=(w>>12)&0xf
        if w: nz+=1
        if tile not in cache: cache[tile]=tile16(tile)
        px=cache[tile]
        palbase=(colour+16)*16
        ox,oy=col*16,row*16
        for y in range(16):
            r=img[oy+y]
            for x in range(16):
                R,G,B=pen(palbase+px[y][x])
                o=(ox+x)*3; r[o]=R; r[o+1]=G; r[o+2]=B
write_png(os.path.join(d,"frame_pf2_map.png"), W, H, img)
print("PF2 map: %d nonzero tiles, %d unique tiles -> frame_pf2_map.png (%dx%d)"%(nz,len(cache),W,H))

# palette swatch (16x16 grid of the 256 entries that matter, 16px each) for sanity
PW=16*16
sw=[bytearray(PW*3) for _ in range(PW)]
for i in range(256):
    R,G,B=pen(i+256)            # PF2 region is palette 256..511
    cx,cy=(i%16)*16,(i//16)*16
    for y in range(16):
        for x in range(16):
            o=(cx+x)*3; sw[cy+y][o]=R; sw[cy+y][o+1]=G; sw[cy+y][o+2]=B
write_png(os.path.join(d,"frame_pal256.png"), PW, PW, sw)
print("wrote frame_pal256.png (palette 256..511)")
