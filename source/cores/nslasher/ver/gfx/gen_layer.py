#!/usr/bin/env python3
# Per-layer golden generator for the generalized jtnslasher_tilemap, driven by a captured MAME
# frame. Renders any PF layer's {colour[3:0],pix[3:0]} screen stream (320x240) using the exact
# deco32 spec (8x8 vs 16x16 scan/geom, tile bank, scroll from the real control regs), and emits
# a Verilog include (layer_cfg.vh) so tb_layer.v reads the matching pf/gfx + tile8/bank/scroll.
#
#   usage: gen_layer.py <caps_dir> <frame> <pf1|pf2|pf3|pf4>
# deco32 wiring (doc/mame_deco32.c get_pfN_tile_info + VIDEO_START/UPDATE(nslasher)):
#   PF1 8x8  region0 gfx1_chars8   bank=0                         colourbase 0
#   PF2 16x16 region1 gfx1_tiles16 bank=((ctl12[7]>>12)&3)        colourbase 16
#   PF3 16x16 region2 gfx2_tiles16 bank=((ctl34[7]>> 4)&3)        colourbase 0
#   PF4 16x16 region2 gfx2_tiles16 bank=((ctl34[7]>>12)&3)        colourbase 16
import os, sys, zlib, struct
d = os.path.dirname(os.path.abspath(__file__))
caps, frame, layer = sys.argv[1], int(sys.argv[2]), sys.argv[3]

def loadhex(p):  return [int(l,16) for l in open(p) if l.strip() and l[0] not in '/@']
def cap(name):   return loadhex(os.path.join(caps, "f%04d_%s.hex"%(frame,name)))

pf_idx = {"pf1":1,"pf2":2,"pf3":3,"pf4":4}[layer]
pf  = cap("pf%d"%pf_idx)
c12 = cap("ctl12"); c34 = cap("ctl34"); PAL = cap("pal")
g = lambda L,i:(L[i]&0xffff) if i<len(L) else 0

# per-layer parameters
if   layer=="pf1": tile8,gfxf,bank,scrx,scry,base = 1,"gfx1_chars8", 0,                   g(c12,1)&0x1ff, g(c12,2)&0xff,  0
elif layer=="pf2": tile8,gfxf,bank,scrx,scry,base = 0,"gfx1_tiles16",(g(c12,7)>>12)&3,     g(c12,3)&0x3ff, g(c12,4)&0x1ff, 16
elif layer=="pf3": tile8,gfxf,bank,scrx,scry,base = 0,"gfx2_tiles16",(g(c34,7)>> 4)&3,     g(c34,1)&0x3ff, g(c34,2)&0x1ff, 0
elif layer=="pf4": tile8,gfxf,bank,scrx,scry,base = 0,"gfx2_tiles16",(g(c34,7)>>12)&3,     g(c34,3)&0x3ff, g(c34,4)&0x1ff, 16
else: sys.exit("layer must be pf1..pf4")

gfx = open(os.path.join(d, gfxf+".bin"),'rb').read()
print("layer=%s frame=%d tile8=%d bank=%d scroll=(%d,%d) gfx=%s base=%d"%(layer,frame,tile8,bank,scrx,scry,gfxf,base))

def gpix(tile,y,x):
    if tile8:
        o = tile*32 + y*4; k = 7-x
    else:
        half = 1 if x>=8 else 0; o = tile*128 + (y*2+half)*4; k = 7-(x&7)
    if o+4 > len(gfx): return 0
    w = gfx[o]|(gfx[o+1]<<8)|(gfx[o+2]<<16)|(gfx[o+3]<<24)
    return ((w>>k)&1)|(((w>>(8+k))&1)<<1)|(((w>>(16+k))&1)<<2)|(((w>>(24+k))&1)<<3)

def scan(col,row):
    if tile8: return ((row&0x1f)<<6) | (col&0x3f)               # row*64+col
    return (col&0x1f)+((row&0x1f)<<5)+((col&0x20)<<5)+((row&0x20)<<6)

W,H = 320,240
MX = 0x1ff if tile8 else 0x3ff
MY = 0xff  if tile8 else 0x1ff
SH = 3 if tile8 else 4
BG = PAL[0x200] if 0x200<len(PAL) else 0
golden=[]; img=[bytearray(W*3) for _ in range(H)]
for sy in range(H):
    for sx in range(W):
        mapx=(sx+scrx)&MX; mapy=(sy+scry)&MY
        col=mapx>>SH; row=mapy>>SH; subx=mapx&((1<<SH)-1); suby=mapy&((1<<SH)-1)
        w=pf[scan(col,row)]&0xffff; tile=(w&0xfff)|(bank<<12); colour=(w>>12)&0xf
        pix=gpix(tile,suby,subx)
        golden.append((colour<<4)|pix)
        idx=(colour+base)*16+pix
        rgb = BG if pix==0 else (PAL[idx] if idx<len(PAL) else 0xff00ff)
        R,G,B = rgb&0xff,(rgb>>8)&0xff,(rgb>>16)&0xff
        o=sx*3; img[sy][o]=R; img[sy][o+1]=G; img[sy][o+2]=B

open(os.path.join(d,"golden_pxl.hex"),'w').write('\n'.join("%02x"%v for v in golden)+'\n')
def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
raw=b''.join(b'\x00'+bytes(r) for r in img)
open(os.path.join(d,"golden_layer.png"),'wb').write(
    b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",W,H,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))

# Verilog config for tb_layer.v
pf_path  = os.path.join(caps, "f%04d_pf%d.hex"%(frame,pf_idx))
gfx_path = os.path.join(d, gfxf+".hex")
with open(os.path.join(d,"layer_cfg.vh"),'w') as f:
    f.write("`define TILE8 1'd%d\n`define BANK 2'd%d\n`define SCRX 10'd%d\n`define SCRY 9'd%d\n"%(tile8,bank,scrx,scry))
    f.write('`define PFFILE "%s"\n`define GFXFILE "%s"\n'%(pf_path.replace("\\","/"), gfx_path.replace("\\","/")))
print("wrote golden_pxl.hex (%d px) + golden_layer.png + layer_cfg.vh"%len(golden))
