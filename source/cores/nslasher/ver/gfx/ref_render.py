#!/usr/bin/env python3
# Full-frame REFERENCE renderer for VIDEO_UPDATE(nslasher) (deco32_pri=0 path) — composites
# PF4/PF3/PF2 + dual sprite layers (priority/alpha) + PF1 + the Ace palette fade, then pixel-diffs
# against the MAME screenshot. This locks the entire video spec before RTL (becomes the RTL golden).
#   usage: ref_render.py [frame=1800]
# Refs: doc/mame_deco32.c VIDEO_UPDATE(nslasher), mixDualAlphaSprites, updateAceRam, get_pfN_tile_info.
import os, sys, zlib, struct
frame = int(sys.argv[1]) if len(sys.argv)>1 else 1800
d   = os.path.dirname(os.path.abspath(__file__))
caps= "/path/to/nightslashers/mame-dump/caps"
rom = "/path/to/nightslashers/roms"
TARGETS=[1,120,240,360,480,600,720,900,1080,1200,1500,1800]
shot= "/path/to/nightslashers/mame-dump/snap/nslashers/%04d.png"%TARGETS.index(frame)
W,H=320,240
def hexf(n): return [int(l,16) for l in open(os.path.join(caps,"f%04d_%s.hex"%(frame,n))) if l.strip() and l[0] not in '/@']

# ---------- palette + Ace fade (updateAceRam) ----------
PALraw=hexf("pal"); ACE=hexf("ace")
def aceb(k): return (ACE[k]&0xff) if k<len(ACE) else 0
ftr,ftg,ftb,fsr,fsg,fsb = aceb(0x20),aceb(0x21),aceb(0x22),aceb(0x23),aceb(0x24),aceb(0x25)
pens=[]
for i,w in enumerate(PALraw):
    r,g,b = w&0xff,(w>>8)&0xff,(w>>16)&0xff
    if i>255:
        r=int(r+((ftr-r)*fsr/255.0)); g=int(g+((ftg-g)*fsg/255.0)); b=int(b+((ftb-b)*fsb/255.0))
    pens.append((r&0xff,g&0xff,b&0xff))
def pen(i): return pens[i] if 0<=i<len(pens) else (255,0,255)

# ---------- PF tilemaps ----------
c12=hexf("ctl12"); c34=hexf("ctl34"); g=lambda L,i:(L[i]&0xffff) if i<len(L) else 0
def gbin(name): return open(os.path.join(d,name+".bin"),'rb').read()
GFX={'pf1':gbin("gfx1_chars8"),'pf2':gbin("gfx1_tiles16"),'pf3':gbin("gfx2_tiles16"),'pf4':gbin("gfx2_tiles16")}
def gpix(gx,tile,y,x,t8):
    if t8: o=tile*32+y*4; k=7-x
    else:
        half=1 if x>=8 else 0; o=tile*128+(y*2+half)*4; k=7-(x&7)
    if o+4>len(gx): return 0
    w=gx[o]|(gx[o+1]<<8)|(gx[o+2]<<16)|(gx[o+3]<<24)
    return ((w>>k)&1)|(((w>>(8+k))&1)<<1)|(((w>>(16+k))&1)<<2)|(((w>>(24+k))&1)<<3)
# layer params: tile8, gfx, bank, scrx, scry, colourbase(GFXDECODE), colourbank
LP={
 'pf1':(1,'pf1',0,                 g(c12,1)&0x1ff, g(c12,2)&0xff,  0,   0),
 'pf2':(0,'pf2',(g(c12,7)>>12)&3,  g(c12,3)&0x3ff, g(c12,4)&0x1ff, 0,   16),
 'pf3':(0,'pf3',(g(c34,7)>> 4)&3,  g(c34,1)&0x3ff, g(c34,2)&0x1ff, 512, 0),
 'pf4':(0,'pf4',(g(c34,7)>>12)&3,  g(c34,3)&0x3ff, g(c34,4)&0x1ff, 512, 16),
}
ENA={'pf1':g(c12,5)&0x0080,'pf2':g(c12,5)&0x8000,'pf3':g(c34,5)&0x0080,'pf4':g(c34,5)&0x8000}
def render_pf(layer):
    t8,gxk,bank,scrx,scry,cbase,cbank=LP[layer]; gx=GFX[gxk]; pf=hexf(layer)
    MX=0x1ff if t8 else 0x3ff; MY=0xff if t8 else 0x1ff; SH=3 if t8 else 4
    out=[[None]*W for _ in range(H)]; raw=[[0]*W for _ in range(H)]
    if not ENA[layer]: return out, raw
    for sy in range(H):
        for sx in range(W):
            mapx=(sx+scrx)&MX; mapy=(sy+scry)&MY
            col=mapx>>SH; row=mapy>>SH; subx=mapx&((1<<SH)-1); suby=mapy&((1<<SH)-1)
            if t8: scan=((row&0x1f)<<6)|(col&0x3f)
            else:  scan=(col&0x1f)+((row&0x1f)<<5)+((col&0x20)<<5)+((row&0x20)<<6)
            w=pf[scan]&0xffff; tile=(w&0xfff)|(bank<<12); colour=(w>>12)&0xf
            pix=gpix(gx,tile,suby,subx,t8)
            raw[sy][sx]=(colour<<4)|pix
            if pix: out[sy][sx]=cbase+(colour+cbank)*16+pix
    return out, raw

# ---------- sprites (deco32_draw_sprite -> 16b mix = (colour<<8)|c) ----------
def rd(f): return open(os.path.join(rom,f),'rb').read()
def l16(reg,off,data):
    for i,b in enumerate(data): reg[off+i*2]=b
def l32(reg,off,data):
    for i,b in enumerate(data): reg[off+i*4]=b
g3=bytearray(0xa00000); l16(g3,1,rd("mbh-02.14c")); l16(g3,0,rd("mbh-04.16c")); l16(g3,0x400001,rd("mbh-03.15c")); l16(g3,0x400000,rd("mbh-05.17c")); l32(g3,0x500000,rd("mbh-06.18c")); l32(g3,0x900000,rd("mbh-07.19c"))
g4=bytearray(0x100000); l16(g4,1,rd("mbh-08.16e")); l16(g4,0,rd("mbh-09.18e"))
XO=[64*8+i for i in range(8)]+[i for i in range(8)]; YO=[i*32 for i in range(16)]; INC=128*8
SLAY={3:(g3,5,[(0xa00000//2)*8,16,0,24,8]),4:(g4,4,[16,0,24,8])}
_sc={}
def stile(bank,code):
    key=(bank,code)
    if key in _sc: return _sc[key]
    reg,planes,po=SLAY[bank]; base=code*INC; out=[[0]*16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            v=0
            for p in range(planes):
                bit=base+po[p]+YO[y]+XO[x]; v|=((reg[bit>>3]>>(7-(bit&7)))&1)<<(planes-1-p)
            out[y][x]=v
    _sc[key]=out; return out
def render_spr(name,bank):
    spr=hexf(name); mix=[[0]*W for _ in range(H)]
    for offs in range(0,0x400,4):
        y=spr[offs]&0xffff; code=spr[offs+1]&0xffff; x=spr[offs+2]&0xffff
        colour=(x>>9)&0x7f
        if y&0x8000: colour|=0x80
        fx=0 if (y&0x2000) else 1; fy=0 if (y&0x4000) else 1
        multi=(1<<((y&0x600)>>9))-1
        sx=x&0x1ff; sy=y&0x1ff
        if sx>=320: sx-=512
        if sy>=256: sy-=512
        code&=~multi; inc=-1 if (y&0x4000) else 1
        if not (y&0x4000): code+=multi
        mixhi=(colour<<8)
        m=multi
        while m>=0:
            px=stile(bank,code-m*inc); ty=sy+16*m
            for ry in range(16):
                yy=ty+ry
                if 0<=yy<H:
                    syc=15-ry if fy else ry
                    for rx in range(16):
                        xx=sx+rx
                        if 0<=xx<W:
                            c=px[syc][15-rx if fx else rx]
                            if c: mix[yy][xx]=mixhi|c     # later sprite overwrites (back->front)
            m-=1
    return mix

# ---------- composite (VIDEO_UPDATE nslasher, deco32_pri==0) ----------
PRI=(hexf("pri")[0]&3) if os.path.exists(os.path.join(caps,"f%04d_pri.hex"%frame)) else 0
if len(sys.argv)>2: PRI=int(sys.argv[2])               # override (the 0x150000 tap is clobbered by eeprom writes)
pf1,pf1r = render_pf('pf1'); pf2,pf2r = render_pf('pf2'); pf3,pf3r = render_pf('pf3'); pf4,pf4r = render_pf('pf4')
# deco32_pri&1 swaps the PF2/PF3 mid(tag2)/front(tag4) draw order (doc/mame_deco32.c VIDEO_UPDATE)
_mid,_fr = (pf2,pf3) if (PRI&1) else (pf3,pf2)
s0,s1 = render_spr('spr0',3),render_spr('spr1',4)
def blend(dst,src):  # MAME alpha_blend_r32(d,s,0x80) == (d+s)>>1 per channel
    return tuple((dc+sc)>>1 for dc,sc in zip(dst,src))
img=[[pen(0x200)]*W for _ in range(H)]; tpri=[[0]*W for _ in range(H)]
_pl0=[0]; _dr0=[0]; _p0h={}; _tprih={}
for y in range(H):
    for x in range(W):
        if pf4[y][x]  is not None: img[y][x]=pen(pf4[y][x]);  tpri[y][x]|=1
        if _mid[y][x] is not None: img[y][x]=pen(_mid[y][x]); tpri[y][x]|=2
        if _fr[y][x]  is not None: img[y][x]=pen(_fr[y][x]);  tpri[y][x]|=4
        # sprite 0 (gfx3)
        m0=s0[y][x]
        if m0&0xff:
            p0=(m0&0x6000)>>13; c0=((m0&0x1f00)>>8)%16; pn=1024+32*c0+(m0&0xff)
            draw = (p0==0 or p0==1) or (p0==2 and tpri[y][x]<4) or (p0==3 and tpri[y][x]<2)
            _pl0[0]+=1; _p0h[p0]=_p0h.get(p0,0)+1; _tprih[tpri[y][x]]=_tprih.get(tpri[y][x],0)+1
            if draw: img[y][x]=pen(pn); _dr0[0]+=1
        # sprite 1 (gfx4) + optional alpha
        m1=s1[y][x]
        if m1&0xff:
            p1=(m1&0x6000)>>13; c1=((m1&0x0f00)>>8)%32; pn=1536+16*c1+(m1&0xff); a1=m1&0x8000
            s0empty = (m0&0xff)==0; p0=(m0&0x6000)>>13
            over0 = s0empty or (p0 not in (0,1,2))
            if a1:
                if (p1==0 and over0) or (p1==1 and over0) or p1==2 or p1==3:
                    img[y][x]=blend(img[y][x],pen(pn))
            else:
                if (p1==0 and (s0empty or p0!=0)) or p1 in (1,2,3):
                    img[y][x]=pen(pn)
        if pf1[y][x] is not None: img[y][x]=pen(pf1[y][x])

# ---------- output + diff vs screenshot ----------
def wpng(path,rows):
    def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
    raw=b''.join(b'\x00'+b''.join(struct.pack("BBB",*px) for px in row) for row in rows)
    open(path,'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",W,H,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))
wpng(os.path.join(d,"ref_f%d.png"%frame), img)
print("PRI=%d  wrote ref_f%d.png"%(PRI,frame))
print("DIAG sprite0: placed=%d drawn=%d  p0 hist=%s  tpri@placed hist=%s"%(_pl0[0],_dr0[0],_p0h,_tprih))

# ---- dump colmix unit-test inputs/golden (feed jtnslasher_colmix the same layer streams) ----
def dumpg(fn, grid, fmt):
    open(os.path.join(d,fn),'w').write('\n'.join(fmt%grid[y][x] for y in range(H) for x in range(W))+'\n')
dumpg("cm_pf1.hex",pf1r,"%02x"); dumpg("cm_pf2.hex",pf2r,"%02x"); dumpg("cm_pf3.hex",pf3r,"%02x"); dumpg("cm_pf4.hex",pf4r,"%02x")
dumpg("cm_obj0.hex",s0,"%04x"); dumpg("cm_obj1.hex",s1,"%04x")
open(os.path.join(d,"cm_rgb.hex"),'w').write('\n'.join("%06x"%((img[y][x][2]<<16)|(img[y][x][1]<<8)|img[y][x][0]) for y in range(H) for x in range(W))+'\n')
palpath=os.path.join(caps,"f%04d_pal.hex"%frame).replace("\\","/")
open(os.path.join(d,"colmix_cfg.vh"),'w').write(
    "`define PRI 2'd%d\n`define EN1 1'b%d\n`define EN2 1'b%d\n`define EN3 1'b%d\n`define EN4 1'b%d\n`define PALFILE \"%s\"\n"%(
    PRI&3, 1 if ENA['pf1'] else 0, 1 if ENA['pf2'] else 0, 1 if ENA['pf3'] else 0, 1 if ENA['pf4'] else 0, palpath))
print("dumped colmix unit-test: cm_{pf1-4,obj0-1,rgb}.hex + colmix_cfg.vh (PRI=%d)"%(PRI&3))

def rpng(path):
    sig=open(path,'rb').read(); assert sig[:8]==b'\x89PNG\r\n\x1a\n'
    i=8; w=h=ct=0; idat=b''
    while i<len(sig):
        ln=struct.unpack(">I",sig[i:i+4])[0]; typ=sig[i+4:i+8]; dat=sig[i+8:i+8+ln]; i+=12+ln
        if typ==b'IHDR': w,h,bd,ct=struct.unpack(">IIBB",dat[:10])
        elif typ==b'IDAT': idat+=dat
        elif typ==b'IEND': break
    raw=zlib.decompress(idat); ch=4 if ct==6 else 3; stride=w*ch; out=[]; prev=bytes(stride)
    pos=0
    def pa(a,b,c):
        p=a+b-c; pa_=abs(p-a); pb=abs(p-b); pc=abs(p-c)
        return a if (pa_<=pb and pa_<=pc) else (b if pb<=pc else c)
    for y in range(h):
        f=raw[pos]; line=bytearray(raw[pos+1:pos+1+stride]); pos+=1+stride
        for x in range(stride):
            a=line[x-ch] if x>=ch else 0; b=prev[x]; c=prev[x-ch] if x>=ch else 0
            if f==1: line[x]=(line[x]+a)&0xff
            elif f==2: line[x]=(line[x]+b)&0xff
            elif f==3: line[x]=(line[x]+((a+b)>>1))&0xff
            elif f==4: line[x]=(line[x]+pa(a,b,c))&0xff
        prev=bytes(line); out.append([(line[x*ch],line[x*ch+1],line[x*ch+2]) for x in range(w)])
    return w,h,out

if os.path.exists(shot):
    sw,sh,sp=rpng(shot)
    print("screenshot %dx%d  render %dx%d"%(sw,sh,W,H))
    for dy in (0,8,-8):                         # try vertical alignment offsets
        n=match=0
        for y in range(H):
            yy=y+dy
            if yy<0 or yy>=sh: continue
            for x in range(min(W,sw)):
                n+=1
                if img[y][x]==sp[yy][x]: match+=1
        if n: print("  align dy=%+d : %d/%d exact RGB (%.2f%%)"%(dy,match,n,100.0*match/n))
else:
    print("no screenshot at",shot)
