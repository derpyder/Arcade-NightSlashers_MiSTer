#!/usr/bin/env python3
# 7c-3a — Python golden for the ROM download transform (raw ROMs -> render-format SDRAM image).
# Models the post-pass as the composition the RTL must reproduce, and verifies each region BYTE-EXACT
# against the already-validated render-format (.bin from decode_gfx.py + reshuffle_gfx.py). This nails
# the exact address maps + decrypt tables BEFORE any RTL.
#
# Pipelines (per region):
#   gfx1 (mbh-00, deco56) -> reorder -> decrypt -> reshuffle(chars8 + tiles16)   [PF1 + PF2]
#   gfx2 (mbh-01, deco74) -> reorder -> decrypt -> reshuffle(tiles16)            [PF3/PF4]
#   gfx3 (mbh-02..07, scattered) PLAIN -> reshuffle(5bpp) -> split obj0lo+obj0hi [obj0]
#   gfx4 (mbh-08/09)             PLAIN -> reshuffle(4bpp)                        [obj1]
#
# The decrypt is expressed SOURCE-STREAMING (the order the download delivers words) using the INVERSE
# address table, which is the form the RTL post-pass / at-fetch wrapper needs:
#   for source word w: dest word i = (w & ~0x7ff) | inv_addr[w & 0x7ff]
#   decword[i] = BITSWAP16( srcword[w] ^ xor_masks[xor_table[w&0x7ff]], swap_patterns[swap_table[i&0x7ff]] )
import os, re, sys
d = os.path.dirname(os.path.abspath(__file__))
CRPT = os.path.join(d, "..", "..", "doc", "decocrpt.c")

# ---- parse decocrpt.c tables (same parser as decode_gfx.py) ----
def parse_c_arrays(path):
    txt = re.sub(r'/\*.*?\*/', '', open(path).read(), flags=re.S)
    out = {}
    for m in re.finditer(r'(?:static\s+)?const\s+\w+\s+(\w+)\s*(\[[^\]]*\])+\s*=\s*\{(.*?)\};', txt, re.S):
        out[m.group(1)] = [int(x,0) for x in re.findall(r'0x[0-9a-fA-F]+|\d+', m.group(3))]
    return out
T = parse_c_arrays(CRPT)
xor_masks     = T['xor_masks']
swap_patterns = [T['swap_patterns'][i*16:(i+1)*16] for i in range(8)]

def bitswap16(v, pat):
    r = 0
    for i, b in enumerate(pat):
        if (v >> b) & 1: r |= 1 << (15 - i)
    return r

# ---- decrypt, expressed SOURCE-STREAMING via the inverse address table ----
def make_inv(address_table):
    # address_table maps dest-page-index -> src-page-index (0..0x7ff). Build src -> dest.
    inv = [0]*0x800
    for i in range(0x800): inv[address_table[i]] = i
    return inv

def decrypt_stream(reordered, xor_table, address_table, swap_table):
    n = len(reordered)//2
    words = [(reordered[2*i]<<8)|reordered[2*i+1] for i in range(n)]   # big-endian
    inv = make_inv(address_table)
    out = [0]*n
    for w in range(n):                       # stream source words in order
        page = w & ~0x7ff
        i = page | inv[w & 0x7ff]             # this source word feeds dest word i
        x = xor_masks[xor_table[w & 0x7ff]]
        out[i] = bitswap16(words[w] ^ x, swap_patterns[swap_table[i & 0x7ff]])
    b = bytearray(n*2)
    for i,wd in enumerate(out):
        b[2*i] = (wd>>8)&0xff; b[2*i+1] = wd&0xff   # big-endian write-back
    return bytes(b)

def reorder(data):                            # nslasher DRIVER_INIT: swap 0x80000 chunks @0x80000<->0x100000
    dd = bytearray(data)
    a,b = 0x80000, 0x100000
    dd[a:a+0x80000], dd[b:b+0x80000] = data[b:b+0x80000], data[a:a+0x80000]
    return bytes(dd)

ROM = os.environ.get("ROMDIR", os.path.join(d, "..", "..", "..", "roms"))
rd = lambda f: open(os.path.join(ROM, f), 'rb').read()

print("=== gfx1 (deco56) reorder+decrypt vs decode_gfx golden (gfx1_dec.bin) ===")
g1_raw = rd("mbh-00.8c")
g1_dec = decrypt_stream(reorder(g1_raw), T['deco56_xor_table'], T['deco56_address_table'], T['deco56_swap_table'])
ref1 = open(os.path.join(d,"gfx1_dec.bin"),'rb').read()
print("  gfx1 decrypt (source-streaming) == decode_gfx:", g1_dec == ref1)

print("=== gfx2 (deco74) reorder+decrypt vs gfx2_dec.bin ===")
g2_raw = rd("mbh-01.9c")
g2_dec = decrypt_stream(reorder(g2_raw), T['deco74_xor_table'], T['deco74_address_table'], T['deco74_swap_table'])
ref2 = open(os.path.join(d,"gfx2_dec.bin"),'rb').read()
print("  gfx2 decrypt (source-streaming) == decode_gfx:", g2_dec == ref2)

# ============ reshuffle as a PURE ADDRESS PERMUTATION (post_addr); verified vs the render-format ============
# Each render-format output byte = one decrypted/raw byte VERBATIM at a permuted address (proven bijective).
HALF1 = len(g1_dec)//2   # RGN_FRAC(1,2): planes 2,3 live in the 2nd ROM half. 0x100000 for 2 MB.

def reshuffle_tiles16(dec, HALF):     # 16x16: out word = t*32+y*2+half, byte k(plane) ; bijection
    ntiles = len(dec)//2//64
    out = bytearray(len(dec))
    for t in range(ntiles):
        for y in range(16):
            for half in range(2):
                ow = t*32 + y*2 + half
                hs = 32 if half==0 else 0
                for k in range(4):
                    out[ow*4+k] = dec[(k&1) + (HALF if (k>>1) else 0) + t*64 + y*2 + hs]
    return bytes(out)

def reshuffle_chars8(dec, HALF):      # 8x8: inc=16 B/tile, 1 half, out word = t*8+y, byte k(plane)
    nch = len(dec)//2//16
    out = bytearray(len(dec))
    for t in range(nch):
        for y in range(8):
            ow = t*8 + y
            for k in range(4):
                out[ow*4+k] = dec[(k&1) + (HALF if (k>>1) else 0) + t*16 + y*2]
    return bytes(out)

print("=== gfx1/gfx2 reshuffle (post_addr permutation) vs render-format .bin ===")
for tag, dec, fn, HALF in [("gfx1_tiles16", g1_dec, reshuffle_tiles16, HALF1),
                           ("gfx1_chars8",  g1_dec, reshuffle_chars8,  HALF1),
                           ("gfx2_tiles16", g2_dec, reshuffle_tiles16, len(g2_dec)//2)]:
    ref = open(os.path.join(d, tag+".bin"),'rb').read()
    got = fn(dec, HALF)
    print("  %-14s == render-format:" % tag, got == ref)

# ============ gfx3/gfx4 PLAIN sprites: scattered assembly -> reshuffle(5bpp/4bpp) -> obj0 split ============
def l16(reg,off,data):
    for i,b in enumerate(data): reg[off+i*2]=b
def l32(reg,off,data):
    for i,b in enumerate(data): reg[off+i*4]=b
g3=bytearray(0xa00000)                # MRA-assembled gfx3 (the post-pass sees this in address order)
l16(g3,1,rd("mbh-02.14c")); l16(g3,0,rd("mbh-04.16c"))
l16(g3,0x400001,rd("mbh-03.15c")); l16(g3,0x400000,rd("mbh-05.17c"))
l32(g3,0x500000,rd("mbh-06.18c")); l32(g3,0x900000,rd("mbh-07.19c"))
g4=bytearray(0x100000); l16(g4,1,rd("mbh-08.16e")); l16(g4,0,rd("mbh-09.18e"))

# sprite reshuffle as an address permutation: out half-row word = code*32 + row*2 + half ; the BPP plane
# bytes (byte p, p=0..BPP-1) come from native plane offsets po (verbatim bytes). The 40-bit obj0 word is
# SPLIT in SDRAM: obj0lo = bytes 0-3 (planes 0-3, 32b), obj0hi = byte 4 (plane 4, 8b).
def spr_src(code, row, half, p, po):
    # native bit base = code*INC + po[p] + YO[row] + XO[half-byte]; /8 -> the verbatim source byte
    INC = 128*8; bit = code*INC + po[p] + row*32 + (64*8 if half==0 else 0)
    return bit >> 3
PO5 = [(0xa00000//2)*8, 16, 0, 24, 8]   # gfx3 5bpp (plane4 in the RGN_FRAC upper half)
PO4 = [16, 0, 24, 8]                     # gfx4 4bpp

# verify against reshuffle_spr's used-tile golden (the validated 40-bit / 32-bit hex)
def load_spr_hex(name):
    words={}; addr=0
    for l in open(os.path.join(d, name+".hex")):
        l=l.strip()
        if not l: continue
        if l[0]=='@': addr=int(l[1:],16); continue
        words[addr]=int(l,16); addr+=1
    return words
def build_word(reg, code, row, half, bpp, po):
    val=0
    for p in range(bpp):                         # output byte p <- native plane po[bpp-1-p] (MSB-first)
        val |= reg[spr_src(code,row,half,bpp-1-p,po)] << (8*p)
    return val
ok3=ok4=True
o0=load_spr_hex("gfx3_spr")
for a,w in o0.items():
    code=a//32; rh=a%32; row=rh//2; half=rh%2
    got=build_word(g3,code,row,half,5,PO5)
    lo=got&0xffffffff; hi=(got>>32)&0xff           # obj0lo + obj0hi split
    if (hi<<32)|lo != w: ok3=False
print("=== gfx3 5bpp reshuffle+split (obj0lo|obj0hi) == reshuffle_spr golden:", ok3, "===")
o1=load_spr_hex("gfx4_spr")
for a,w in o1.items():
    code=a//32; rh=a%32; row=rh//2; half=rh%2
    if build_word(g4,code,row,half,4,PO4) != w: ok4=False
print("=== gfx4 4bpp reshuffle == reshuffle_spr golden:", ok4, "===")

# ============ ARCH B: AT-FETCH decrypt+reshuffle wrapper model (the RTL spec) ============
# SDRAM holds reorder(raw) for gfx1/gfx2 (16-bit encrypted words). The wrapper, given a tilemap
# render-word address rom_addr, reads TWO decrypted words (W, W+0x80000), and assembles the 32-bit
# render word = { byteswap(decword[W+0x80000]), byteswap(decword[W]) }.  Verified == render-format.
class Tab:
    def __init__(self, pre):
        self.addr = T[pre+'_address_table']; self.xor = T[pre+'_xor_table']; self.swap = T[pre+'_swap_table']
def decword_at(reord, i, tab):                       # reord = reorder(raw) bytes, BE 16-bit words
    a = (i & ~0x7ff) | tab.addr[i & 0x7ff]
    E = (reord[2*a] << 8) | reord[2*a+1]
    return bitswap16(E ^ xor_masks[tab.xor[a & 0x7ff]], swap_patterns[tab.swap[i & 0x7ff]])
def bswap16(w): return ((w & 0xff) << 8) | (w >> 8)
def fetch_render(reord, rom_addr, chars8, tab):
    if chars8:
        W = rom_addr                                  # {tile_id,suby[2:0]} = tile*8 + suby
    else:
        tile_id = rom_addr >> 5; suby = (rom_addr >> 1) & 0xf; half = rom_addr & 1
        W = tile_id*32 + suby + (0 if half else 16)
    d1 = decword_at(reord, W, tab); d2 = decword_at(reord, W+0x80000, tab)
    return (bswap16(d2) << 16) | bswap16(d1)
def render_word_of(binf, wa):                          # 32-bit render word at addr wa from a .bin
    o = wa*4; return binf[o] | (binf[o+1]<<8) | (binf[o+2]<<16) | (binf[o+3]<<24)

r1 = reorder(g1_raw); r2 = reorder(g2_raw)             # SDRAM contents (gfx1/gfx2)
deco56 = Tab('deco56'); deco74 = Tab('deco74')

# ---- emit the RTL artifacts for the at-fetch wrapper sim (down_pass.py emit) ----
if len(sys.argv) > 1 and sys.argv[1] == "emit":
    def emit_tab(pre, tab):
        with open(os.path.join(d, pre+"_address.hex"),"w") as f:
            for v in tab.addr: f.write("%03x\n" % v)      # 11-bit
        with open(os.path.join(d, pre+"_xor.hex"),"w") as f:
            for v in tab.xor:  f.write("%x\n" % v)        # 4-bit
        with open(os.path.join(d, pre+"_swap.hex"),"w") as f:
            for v in tab.swap: f.write("%x\n" % v)        # 3-bit
    emit_tab("deco56", deco56); emit_tab("deco74", deco74)
    # reorder(raw) as 16-bit BE words = the gfx1/gfx2 SDRAM contents
    for nm, rr in [("r1_gfx1", r1), ("r2_gfx2", r2)]:
        with open(os.path.join(d, nm+".hex"),"w") as f:
            for i in range(len(rr)//2): f.write("%04x\n" % ((rr[2*i]<<8)|rr[2*i+1]))
    # shared xor_masks (16x16b) + swap_patterns (8x16b bit-position lists) -> a Verilog include
    with open(os.path.join(d, "deco_consts.vh"),"w") as f:
        for j,m in enumerate(xor_masks): f.write("localparam [15:0] XORM%d = 16'h%04x;\n" % (j,m))
        for s in range(8):
            # bitswap16(v,pat): out[15-k] = v[pat[k]] ; emit as a concat for RTL function
            terms = ",".join("v[%d]"%swap_patterns[s][k] for k in range(16))
            f.write("`define SWAP%d(v) {%s}\n" % (s, terms))
    # native obj SDRAM layout (Arch B at-fetch: adapter rewires hra->nwi; SDRAM holds NATIVE, indexed
    # by nwi). obj0lo = native 32-bit word (byte-lane k = g3[nwi*4+k]); obj0hi = dense plane4 byte;
    # obj1 = native gfx4 word. Sparse @nwi over the used tiles (matches the f-frame caps).
    def remap(hra):
        code=hra>>5; rowf=(hra>>1)&0xf; half=hra&1
        return code*32 + rowf + (0 if half else 16)
    nwords = lambda reg,na: reg[na]|(reg[na+1]<<8)|(reg[na+2]<<16)|(reg[na+3]<<24)
    flo=open(os.path.join(d,"obj0lo_native.hex"),"w"); fhi=open(os.path.join(d,"obj0hi_native.hex"),"w")
    for hra in sorted(o0):
        nwi=remap(hra); na=nwi*4
        flo.write("@%x\n%08x\n"%(nwi, nwords(g3,na))); fhi.write("@%x\n%02x\n"%(nwi, g3[na+0x500000]))
    flo.close(); fhi.close()
    with open(os.path.join(d,"obj1_native.hex"),"w") as f1:
        for hra in sorted(o1):
            nwi=remap(hra); f1.write("@%x\n%08x\n"%(nwi, nwords(g4,nwi*4)))
    print("emitted: deco56/74_{address,xor,swap}.hex, r1_gfx1.hex, r2_gfx2.hex, deco_consts.vh,")
    print("         obj0lo_native.hex, obj0hi_native.hex, obj1_native.hex")
    sys.exit(0)
print("=== Arch B at-fetch wrapper model == render-format (sampled, all tiles) ===")
for tag, binf, reord, chars8, tab, nwords in [
        ("PF2 gfx1 tiles16", open(os.path.join(d,"gfx1_tiles16.bin"),'rb').read(), r1, False, deco56, 0x80000),
        ("PF1 gfx1 chars8",  open(os.path.join(d,"gfx1_chars8.bin"),'rb').read(),  r1, True,  deco56, 0x80000),
        ("PF3/4 gfx2 tiles16",open(os.path.join(d,"gfx2_tiles16.bin"),'rb').read(), r2, False, deco74, 0x80000)]:
    bad = 0
    for wa in range(nwords):
        if fetch_render(reord, wa, chars8, tab) != render_word_of(binf, wa):
            bad += 1
            if bad <= 2: print("   mismatch wa=%#x got=%08x ref=%08x" % (wa, fetch_render(reord,wa,chars8,tab), render_word_of(binf,wa)))
    print("  %-20s : %s (%d/%d words)" % (tag, "BIT-EXACT" if bad==0 else "%d BAD"%bad, nwords-bad, nwords))

# ============ 7c-3d Arch B: AT-FETCH obj reshuffle model (the jtnslasher_sdram rewire spec) ============
# SDRAM holds NATIVE gfx3/gfx4. Given the obj rom_addr (hra = code*32 + rowf*2 + half), the adapter
# rewires: native word index nwi = code*32 + rowf + (half?0:16) = {code, ~half, rowf}; the 32-bit native
# word {b3,b2,b1,b0} -> render planes {b2,b0,b3,b1}; plane4 (gfx3) = native byte at nwi*4 + 0x500000.
def obj_fetch(reg, hra, five):
    code = hra >> 5; rowf = (hra >> 1) & 0xf; half = hra & 1
    nwi = code*32 + rowf + (0 if half else 16)
    na = nwi*4
    b0,b1,b2,b3 = reg[na],reg[na+1],reg[na+2],reg[na+3]
    word = b1 | (b3<<8) | (b0<<16) | (b2<<24)          # render planes 0-3 = {b2,b0,b3,b1}
    if five: word |= reg[na + 0x500000] << 32           # plane 4 (gfx3)
    return word
ok0 = ok1 = True
for a,w in o0.items():                                  # o0/o1 = reshuffle_spr golden (loaded above)
    if obj_fetch(g3, a, True)  != w: ok0=False
for a,w in o1.items():
    if obj_fetch(g4, a, False) != w: ok1=False
print("=== 7c-3d at-fetch obj0 (gfx3 5bpp) rewire == reshuffle_spr golden:", ok0, "===")
print("=== 7c-3d at-fetch obj1 (gfx4 4bpp) rewire == reshuffle_spr golden:", ok1, "===")

# ============ 7c-3d: BA2 reorder download post_addr = swap word-addr bits 18<->19 ============
def swap1819(w): return (w & ~(3<<18)) | (((w>>18)&1)<<19) | (((w>>19)&1)<<18)
g1w = [(g1_raw[2*i]<<8)|g1_raw[2*i+1] for i in range(len(g1_raw)//2)]
r1w = [(r1[2*i]<<8)|r1[2*i+1] for i in range(len(r1)//2)]      # reorder(raw) = the SDRAM golden
# post_addr(w)=swap1819(w) => SDRAM[swap1819(w)] = raw[w]; must equal r1 (reorder)
ba2_ok = all(r1w[swap1819(w)] == g1w[w] for w in range(len(g1w)))
print("=== 7c-3d BA2 reorder (post_addr = swap word bits 18<->19) reproduces reorder(raw):", ba2_ok, "===")
