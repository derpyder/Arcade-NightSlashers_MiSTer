#!/usr/bin/env python3
# VISUAL confirmation of the endianness fix: render the gfx3 (obj0) + gfx4 (obj1) sprites for a frame
# from the AUTHORITATIVE big-endian .mra delivery through the CORRECTED unpack (plane4 [7:0], obj1
# hwswap16), and pixel-diff against the MAME-decoded sprite (raw ROMs). Also renders the BROKEN
# (current-flashed) unpack for side-by-side, so the difference is visible.
import os, sys, zlib, struct, re
d   = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", "/path/to/nightslashers/roms")
MRA = "/path/to/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB) FOLD.mra"
caps= "/path/to/nightslashers/mame-dump/caps"
frame = int(sys.argv[1]) if len(sys.argv) > 1 else 6000
romfile = lambda nm: open(os.path.join(ROM, nm), 'rb').read()

# ---- authoritative interleave (mra2rom.go) ----
def interleave2rom(width_bits, parts):
    width = width_bits >> 3
    fingers = [[data, mapstr, max(int(c) for c in mapstr), 0] for data, mapstr in parts]
    sel = [0]*width
    for j in range(width):
        for k in range(len(fingers)):
            if fingers[k][1][j] != '0': sel[j]=k; break
    out = bytearray()
    while True:
        for j in range(width-1, -1, -1):
            f = fingers[sel[j]]; i = f[3] + ((ord(f[1][j])-ord('1'))&0xff)
            out.append(f[0][i] if i < len(f[0]) else 0)
        brk=False
        for f in fingers:
            f[3]+=f[2]
            if f[3]>=len(f[0]): brk=True
        if brk: break
    return bytes(out)
body = re.search(r'<rom index="0"[^>]*>(.*?)</rom>', open(MRA).read(), re.S).group(1)
blob = bytearray()
TOK = re.compile(r'<interleave output="(\d+)">(.*?)</interleave>|<part name="([^"]+)"\s*crc="[^"]*"\s*/>'
                 r'|<part repeat="([^"]+)">\s*([0-9A-Fa-f]+)\s*</part>', re.S)
for t in TOK.finditer(body):
    if t.group(1):
        parts=[(romfile(nm),mp) for nm,mp in re.findall(r'<part name="([^"]+)"[^>]*map="([^"]*)"', t.group(2))]
        blob += interleave2rom(int(t.group(1)), parts)
    elif t.group(3): blob += romfile(t.group(3))
    else: blob += bytes([int(t.group(5),16)])*int(t.group(4),16)

# ---- BIG-ENDIAN bank words + fold remap ----
BA2_START, BA3_START = 0x210000, 0x710000
bw = lambda s,e: [(blob[i]<<8)|blob[i+1] for i in range(s, min(e,len(blob)), 2)]
ba2, ba3 = bw(BA2_START,BA3_START), bw(BA3_START,len(blob))
P4BASE=0x400000
reorder=lambda w:(w&~(3<<18))|(((w>>18)&1)<<19)|(((w>>19)&1)<<18)
sd2={}; sd3={}
for w,v in enumerate(ba2): sd2[reorder(w) if w<0x200000 else w]=v
for w,v in enumerate(ba3): sd3[(((w>>1)<<2)|(w&1)) if w<P4BASE else (((w-P4BASE)<<2)|2)]=v

def hwswap16(x): return (((x>>16)&0xff)<<24)|(((x>>24)&0xff)<<16)|((x&0xff)<<8)|((x>>8)&0xff)
def plane_permute(x): return (((x>>16)&0xff)<<24)|((x&0xff)<<16)|(((x>>24)&0xff)<<8)|((x>>8)&0xff)
def o0_render(nwi, fix):   # 40-bit render word for one (tile,row,half) index
    planes=(sd3.get(4*nwi+1,0)<<16)|sd3.get(4*nwi,0); p4=sd3.get(4*nwi+2,0)
    p4b = (p4&0xff) if fix else (p4>>8)&0xff           # FIX=[7:0], BROKEN=[15:8]
    return (p4b<<32)|plane_permute(hwswap16(planes))
def o1_render(nwi, fix):
    w=(sd2.get(0x200000+2*nwi+1,0)<<16)|sd2.get(0x200000+2*nwi,0)
    return plane_permute(hwswap16(w)) if fix else plane_permute(w)

# ---- decode the 40/32-bit render words into a sprite using the engine's tile layout ----
# render word per (code,row,half): rom_addr = {code,row[3:0],half} -> nwi = {code,~half,row}
def fsm_nwi(code,row,half): return (code<<5)|((0 if half else 1)<<4)|row
def hexf(n): return [int(l,16)&0xffff for l in open(os.path.join(caps,"f%04d_%s.hex"%(frame,n))) if l.strip() and l[0] not in '/@']
PAL=[int(l,16) for l in open(os.path.join(caps,"f%04d_pal.hex"%frame))]
def pen_rgb(i):
    w=PAL[i] if i<len(PAL) else 0; return (w&0xff,(w>>8)&0xff,(w>>16)&0xff)
W,Hh=320,240
def render(layer, bank, bpp, base, gran, fix):
    spr=hexf(layer); img=[[None]*W for _ in range(Hh)]
    for offs in range(0,0x400,4):
        y=spr[offs]; code=spr[offs+1]; x=spr[offs+2]
        colour=(x>>9)&0x7f
        if y&0x8000: colour|=0x80
        fx=0 if (y&0x2000) else 1; fy=0 if (y&0x4000) else 1
        multi=(1<<((y&0x600)>>9))-1; sx=x&0x1ff; sy=y&0x1ff
        if sx>=320: sx-=512
        if sy>=256: sy-=512
        base_code=code&~multi; inc=-1 if (y&0x4000) else 1
        if not (y&0x4000): code+=multi
        col=(colour&0x1f)%16 if bank==3 else (colour&0x0f)
        m=multi
        while m>=0:
            c0=code-m*inc; ty=sy+16*m
            for ry in range(16):
                yy=ty+ry
                if yy<0 or yy>=Hh: continue
                row=15-ry if fy else ry
                # build the 16-px row from the two half render words
                px=[0]*16
                for half in (0,1):
                    nwi=fsm_nwi(c0,row,half)
                    rw = o0_render(nwi,fix) if bank==3 else o1_render(nwi,fix)
                    for i in range(8):
                        v=0
                        for p in range(bpp):
                            v|=((rw>>(8*p+7-i))&1)<<p
                        px[half*8+i]=v
                for rx in range(16):
                    xx=sx+rx
                    if xx<0 or xx>=W: continue
                    c=px[15-rx if fx else rx]
                    if c: img[yy][xx]=base+col*gran+c
    return img
def save(name, *layers):
    bg=pen_rgb(0x200); img=[bytearray(W*3) for _ in range(Hh)]
    for y in range(Hh):
        for x in range(W):
            idx=None
            for L in layers:
                if L[y][x] is not None: idx=L[y][x]
            R,G,B=pen_rgb(idx) if idx is not None else bg
            o=x*3; img[y][o]=R; img[y][o+1]=G; img[y][o+2]=B
    def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
    raw=b''.join(b'\x00'+bytes(r) for r in img)
    open(os.path.join(d,name),'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",W,Hh,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))
    print("wrote",name)

o0_fix=render('spr0',3,5,1024,32,True);  o1_fix=render('spr1',4,4,1536,16,True)
o0_brk=render('spr0',3,5,1024,32,False); o1_brk=render('spr1',4,4,1536,16,False)
save("be_FIXED_f%d.png"%frame, o0_fix, o1_fix)
save("be_BROKEN_f%d.png"%frame, o0_brk, o1_brk)
# pixel-diff the FIXED render vs the MAME-decoded sprite (sprite_render.py golden output exists)
