#!/usr/bin/env python3
# Validate the sprite decode+placement by rendering a captured frame's sprite list and comparing
# to the MAME screenshot. Implements nslasher_draw_sprites + deco32_draw_sprite (doc/mame_deco32.c).
#   usage: sprite_render.py <frame>   (default 1800)
import os, sys, zlib, struct
romdir="/path/to/nightslashers/roms"; d=os.path.dirname(os.path.abspath(__file__))
caps="/path/to/nightslashers/mame-dump/caps"; frame=int(sys.argv[1]) if len(sys.argv)>1 else 1800
rd=lambda f: open(os.path.join(romdir,f),'rb').read()
def loadhex(p): return [int(l,16) for l in open(p) if l.strip() and l[0] not in '/@']
def cap(n): return loadhex(os.path.join(caps,"f%04d_%s.hex"%(frame,n)))

def l16(reg,off,data):
    for i,b in enumerate(data): reg[off+i*2]=b
def l32(reg,off,data):
    for i,b in enumerate(data): reg[off+i*4]=b
g3=bytearray(0xa00000)
l16(g3,1,rd("mbh-02.14c")); l16(g3,0,rd("mbh-04.16c")); l16(g3,0x400001,rd("mbh-03.15c")); l16(g3,0x400000,rd("mbh-05.17c")); l32(g3,0x500000,rd("mbh-06.18c")); l32(g3,0x900000,rd("mbh-07.19c"))
g4=bytearray(0x100000); l16(g4,1,rd("mbh-08.16e")); l16(g4,0,rd("mbh-09.18e"))

XO=[64*8+i for i in range(8)]+[i for i in range(8)]; YO=[i*32 for i in range(16)]; INC=128*8
LAY={3:dict(reg=g3,planes=5,po=[(0xa00000//2)*8,16,0,24,8]), 4:dict(reg=g4,planes=4,po=[16,0,24,8])}
_cache={}
def tile(bank,code):                            # -> 16x16 list of pen values
    key=(bank,code)
    if key in _cache: return _cache[key]
    L=LAY[bank]; reg=L['reg']; po=L['po']; base=code*INC; out=[[0]*16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            v=0
            for p in range(L['planes']):
                bit=base+po[p]+YO[y]+XO[x]
                v|=((reg[bit>>3]>>(7-(bit&7)))&1)<<(L['planes']-1-p)
            out[y][x]=v
    _cache[key]=out; return out

PAL=cap("pal")
def pen_rgb(idx):
    w=PAL[idx] if idx<len(PAL) else 0
    return (w&0xff,(w>>8)&0xff,(w>>16)&0xff)

W,H=320,240
def render(spr, bank, colbase, gran):
    img=[[None]*W for _ in range(H)]
    n=0
    for offs in range(0,0x400,4):               # back-to-front
        y=spr[offs]&0xffff; code=spr[offs+1]&0xffff; x=spr[offs+2]&0xffff
        colour=(x>>9)&0x7f
        if y&0x8000: colour|=0x80
        fx=1 if not (y&0x2000) else 0; fy=1 if not (y&0x4000) else 0
        multi=(1<<((y&0x600)>>9))-1
        sx=x&0x1ff; sy=y&0x1ff
        if sx>=320: sx-=512
        if sy>=256: sy-=512
        code&=~multi
        inc=-1 if (y&0x4000) else 1
        if not (y&0x4000): code+=multi
        col=(colour&0x1f)%16 if bank==3 else (colour&0x0f)
        m=multi
        while m>=0:
            c0=code-m*inc
            px=tile(bank,c0)
            ty=sy+16*m
            for ry in range(16):
                yy=ty+ry
                if yy<0 or yy>=H: continue
                syc=15-ry if fy else ry
                for rx in range(16):
                    xx=sx+rx
                    if xx<0 or xx>=W: continue
                    sxc=15-rx if fx else rx
                    c=px[syc][sxc]
                    if c:
                        img[yy][xx]=colbase+col*gran+c; n+=1
            m-=1
    return img,n

i3,n3=render(cap("spr0"),3,1024,32)
i4,n4=render(cap("spr1"),4,1536,16)
print("spr0(gfx3 5bpp): %d px  spr1(gfx4 4bpp): %d px"%(n3,n4))

def png(path, layers):                          # composite list of pen-index images (later on top), bg=pen 0x200
    bg=pen_rgb(0x200); img=[bytearray(W*3) for _ in range(H)]
    for sy in range(H):
        for sx in range(W):
            idx=None
            for L in layers:
                if L[sy][sx] is not None: idx=L[sy][sx]
            R,G,B = pen_rgb(idx) if idx is not None else bg
            o=sx*3; img[sy][o]=R; img[sy][o+1]=G; img[sy][o+2]=B
    def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
    raw=b''.join(b'\x00'+bytes(r) for r in img)
    open(path,'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",W,H,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))
    print("  wrote",path)

png(os.path.join(d,"spr_f%d_gfx3.png"%frame),[i3])
png(os.path.join(d,"spr_f%d_gfx4.png"%frame),[i4])
png(os.path.join(d,"spr_f%d_both.png"%frame),[i3,i4])
print("compare spr_f%d_both.png vs mame-dump/snap/nslashers/0011.png (f1800)"%frame)
