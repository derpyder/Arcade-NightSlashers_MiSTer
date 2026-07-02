#!/usr/bin/env python3
# bio_render.py — offline validator for MECHANISM B (pri&2 JOINT-8bpp tilemap mode).
# Renders a captured character-bio frame (vancaps, pri=6 confirmed by attract_pri.txt ground truth)
# through the 0284 joint-mode path and pixel-diffs against MAME's own snapshot of the same frame:
#   screen_update_nslasher (deco32_v.cpp:491-495, m_pri&2):
#     backdrop pen 0x300
#     tilegen[1]->tilemap_12_combine_draw : PF3 pixmap | mix_callback with PF4 pixmap, PF3's scroll
#         mix_callback (deco32.cpp:936-939): ((p & 0x70f) + (((p & 0x30) | (p2 & 0x0f)) << 4)) & 0x7ff
#         where p/p2 are pixmap values INCLUDING the static colour banks (tm_bank0=2 -> +0x200,
#         tm_bank1=3 -> +0x300; boot-only writes, attract_pri.txt), trans_mask 0xff (post-mix)
#     tilegen[0]->tilemap_2_draw   : PF2 on top (pen-0 transparent, colour bank 16 -> pens 0x100+)
#     (sprite mix: bio frames have zero live sprites — spr0/spr1 parked at y=0x180, verified)
#     tilegen[0]->tilemap_1_draw   : PF1 text last (pens 0x000+)
#   usage: bio_render.py [frame=3000] [--plain]
#     --plain renders the same frame through the PLAIN (pri&2==0) path = what the current RTL does,
#     for the before/after. Golden: vansnap2/nslashers/%04d.png via vancaps/dumps.txt manifest.
import os, sys, zlib, struct

frame = 3000
plain = "--plain" in sys.argv
for a in sys.argv[1:]:
    if a.isdigit(): frame = int(a)

d    = os.path.dirname(os.path.abspath(__file__))
md   = "/path/to/nightslashers/mame-dump"
if not os.path.isdir(md): md = "/path/to/nightslashers/mame-dump"
caps = md + "/vancaps"
W,H  = 320,240

def hexf(n):
    return [int(l,16) for l in open(os.path.join(caps,"f%05d_%s.hex"%(frame,n))) if l.strip() and l[0] not in '/@']

# ---------- golden snapshot lookup via the manifest ----------
snap = None
for l in open(caps+"/dumps.txt"):
    p = l.split()
    if p and p[0]=="f%05d"%frame: snap = md+"/vansnap2/nslashers/%s.png"%p[1].split('=')[1]
assert snap and os.path.exists(snap), "no snapshot for f%05d"%frame

# ---------- palette + Ace fade (pens>255 lerp; bio frames have fade scale 0 = identity) ----------
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

# ---------- tilemap pixmap sampler (raw {colour,pen}, no colour bank) ----------
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

# per-layer config: (tile8, gfxkey, tile bank<<12 from ctl[7] byte per bank_callback (b&~0xf)<<8)
LAYER={
 'pf1':(1,'pf1',0,                        c12),
 'pf2':(0,'pf2',((g(c12,7)>>8)&0xff),     c12),
 'pf3':(0,'pf3',( g(c34,7)     &0xff),    c34),
 'pf4':(0,'pf4',((g(c34,7)>>8) &0xff),    c34),
}
def sample(layer, sx, sy, scrx, scry):
    """pixmap sample at screen (sx,sy) with the given scroll -> (colour,pen) raw"""
    t8,gxk,bankb,_=LAYER[layer]; gx=GFX[gxk]; pf=hexf(layer)
    MX=0x1ff if t8 else 0x3ff; MY=0xff if t8 else 0x1ff; SH=3 if t8 else 4
    mapx=(sx+scrx)&MX; mapy=(sy+scry)&MY
    col=mapx>>SH; row=mapy>>SH; subx=mapx&((1<<SH)-1); suby=mapy&((1<<SH)-1)
    if t8: scan=((row&0x1f)<<6)|(col&0x3f)
    else:  scan=(col&0x1f)+((row&0x1f)<<5)+((col&0x20)<<5)+((row&0x20)<<6)
    w=pf[scan]&0xffff; tile=(w&0xfff)|(((bankb&~0xf)<<8)); colour=(w>>12)&0xf
    return colour, gpix(gx,tile,suby,subx,t8)

def prerender(layer, scrx, scry):
    t8=LAYER[layer][0]; gx=GFX[LAYER[layer][1]]; pf=hexf(layer); bankb=LAYER[layer][2]
    MX=0x1ff if t8 else 0x3ff; MY=0xff if t8 else 0x1ff; SH=3 if t8 else 4
    out=[[ (0,0) ]*W for _ in range(H)]
    for sy in range(H):
        for sx in range(W):
            mapx=(sx+scrx)&MX; mapy=(sy+scry)&MY
            col=mapx>>SH; row=mapy>>SH; subx=mapx&((1<<SH)-1); suby=mapy&((1<<SH)-1)
            if t8: scan=((row&0x1f)<<6)|(col&0x3f)
            else:  scan=(col&0x1f)+((row&0x1f)<<5)+((col&0x20)<<5)+((row&0x20)<<6)
            w=pf[scan]&0xffff; tile=(w&0xfff)|((bankb&~0xf)<<8); colour=(w>>12)&0xf
            out[sy][sx]=(colour, gpix(gx,tile,suby,subx,t8))
    return out

ENA={'pf1':g(c12,5)&0x0080,'pf2':g(c12,5)&0x8000,'pf3':g(c34,5)&0x0080,'pf4':g(c34,5)&0x8000}
# static colour banks (boot-only 0x164000 writes: tm_bank0=2, tm_bank1=3; PF2 static bank 16, PF1 0)
CB_PF3, CB_PF4, CB_PF2 = 0x200, 0x300, 16

sx3,sy3 = g(c34,1)&0x3ff, g(c34,2)&0x1ff        # PF3 scroll — used for BOTH nibbles in joint mode
sx2,sy2 = g(c12,3)&0x3ff, g(c12,4)&0x1ff
sx1,sy1 = g(c12,1)&0x1ff, g(c12,2)&0xff
sx4,sy4 = g(c34,3)&0x3ff, g(c34,4)&0x1ff

# JOINT mode y offset: custom_tilemap_draw (doc/mame_deco16ic.c:996-998) renders screen rows
# 8..247 from src_y = scrolly+8 -> visible row 0 shows pixmap row scrolly+8. Empirically confirmed
# by bio_align.py: best shift (dx,dy)=(0,8), mismatch 58k -> 4.4k (all PF1 text overlay).
JDY = 8
pf3 = prerender('pf3', sx3, sy3 + (JDY if not plain else 0))
pf4 = prerender('pf4', sx3 if not plain else sx4, (sy3+JDY) if not plain else sy4)  # joint: PF3's scroll
pf2 = prerender('pf2', sx2, sy2 + (JDY if not plain else 0))
pf1 = prerender('pf1', sx1, sy1 + (JDY if not plain else 0))

img=[[pen(0x300)]*W for _ in range(H)]
joint_used={}
for y in range(H):
    for x in range(W):
        if plain:
            # plain path (pri&1==0): PF4 (tag1) -> PF3 (tag2) -> PF2 (tag4)  [what the RTL does today]
            c4,p4 = pf4[y][x]
            if ENA['pf4'] and p4: img[y][x]=pen((CB_PF4 + c4*16 + p4)&0x7ff)
            c3,p3 = pf3[y][x]
            if ENA['pf3'] and p3: img[y][x]=pen((CB_PF3 + c3*16 + p3)&0x7ff)
            c2,p2v = pf2[y][x]
            if ENA['pf2'] and p2v: img[y][x]=pen((0x100 + (c2+0)*16 + p2v)&0x7ff)
        else:
            # JOINT mode: p (PF3) + p2 (PF4) через mix_callback, trans on post-mix low byte
            c3,p3 = pf3[y][x]; c4,p4 = pf4[y][x]
            p  = CB_PF3 | (c3<<4) | p3
            p2 = CB_PF4 | (c4<<4) | p4
            jp = ((p & 0x70f) + (((p & 0x30) | (p2 & 0x0f)) << 4)) & 0x7ff
            if ENA['pf3'] and (jp & 0xff):
                img[y][x]=pen(jp); joint_used[jp]=joint_used.get(jp,0)+1
            c2,p2v = pf2[y][x]
            if ENA['pf2'] and p2v: img[y][x]=pen((0x100 + c2*16 + p2v)&0x7ff)
        c1,p1 = pf1[y][x]
        if ENA['pf1'] and p1: img[y][x]=pen((c1*16 + p1)&0x7ff)

# ---------- PNG out + pixel diff vs the MAME snapshot ----------
def wpng(path,rows):
    def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
    raw=b''.join(b'\x00'+b''.join(struct.pack("BBB",*px) for px in row) for row in rows)
    open(path,'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",W,H,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))
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

tag = "plain" if plain else "joint"
outp = os.path.join(d,"bio_f%05d_%s.png"%(frame,tag))
wpng(outp,img)

# ---------- colmix unit-test dump (joint mode only): per-pixel layer streams + RGB golden ----------
if not plain:
    def wr(fn, lines): open(os.path.join(d,fn),'w').write('\n'.join(lines)+'\n')
    wr("cmb_pf1.hex",  ["%02x"%((c<<4)|p) for row in pf1 for (c,p) in row])
    wr("cmb_pf2.hex",  ["%02x"%((c<<4)|p) for row in pf2 for (c,p) in row])
    wr("cmb_pf3.hex",  ["%02x"%((c<<4)|p) for row in pf3 for (c,p) in row])
    wr("cmb_pf4.hex",  ["%02x"%((c<<4)|p) for row in pf4 for (c,p) in row])   # pre-sampled at PF3's scroll
    wr("cmb_obj0.hex", ["0000"]*(W*H))                                        # bios: sprites parked (verified)
    wr("cmb_obj1.hex", ["0000"]*(W*H))
    wr("cmb_pal.hex",  ["%06x"%(w&0xffffff) for w in PALraw])                 # raw CPU words (0x00BBGGRR)
    wr("cmb_fade.hex", ["%06x"%((b<<16)|(g<<8)|r) for (r,g,b) in pens])       # post-ace-fade (faded half)
    wr("cmb_rgb.hex",  ["%06x"%((px[2]<<16)|(px[1]<<8)|px[0]) for row in img for px in row])
    ace_al = 0
    for k in range(6): ace_al |= aceb(k) << (8*k)
    open(os.path.join(d,"cmb_cfg.vh"),'w').write(
        "`define PRI 3'd6\n`define EN1 1'b%d\n`define EN2 1'b%d\n`define EN3 1'b%d\n`define EN4 1'b%d\n"
        "`define TMB0 3'd2\n`define TMB1 3'd3\n`define O1BASE 3'd6\n`define ACEAL 48'h%012x\n"%(
        1 if ENA['pf1'] else 0, 1 if ENA['pf2'] else 0, 1 if ENA['pf3'] else 0, 1 if ENA['pf4'] else 0, ace_al))
    print("dumped colmix bio test: cmb_{pf1-4,obj0-1,pal,fade,rgb}.hex + cmb_cfg.vh")
sw,sh,sp = rpng(snap)
assert (sw,sh)==(W,H), "snapshot size %dx%d"%(sw,sh)
bad=0; firstbad=None
for y in range(H):
    for x in range(W):
        if sp[y][x]!=img[y][x]:
            bad+=1
            if firstbad is None: firstbad=(x,y,sp[y][x],img[y][x])
print("f%05d %s: %d/%d pixels differ vs MAME snapshot (%s)"%(frame,tag,bad,W*H,os.path.basename(snap)))
if firstbad: print("  first diff at %s: mame=%s model=%s"%(firstbad[0:2],firstbad[2],firstbad[3]))
if not plain:
    lo=min(joint_used) if joint_used else -1; hi=max(joint_used) if joint_used else -1
    print("  joint pens used: %d distinct, range 0x%03x-0x%03x"%(len(joint_used),lo,hi))
print("wrote", outp)
