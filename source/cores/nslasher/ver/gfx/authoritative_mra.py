#!/usr/bin/env python3
# DECISIVE TEST: assemble the FOLD .mra using the AUTHORITATIVE jtframe interleave semantics
# (ported faithfully from modules/jtframe/src/jtframe/mra/mra2rom.go interleave2rom), then run the
# obj0 (planes+plane4) and obj1 unpack and compare to MAME golden render words. The fold .mra was
# hand-built + validated ONLY against validate_fold_mra.py, whose interleave byte order is OPPOSITE
# to mra2rom.go. If the authoritative assembly makes the CURRENT unpack FAIL and a byte-swap-aware
# unpack PASS, that is the cab's "uniform beige" bug (a static .mra-delivery / sim-vs-HW divergence).
import os, re, sys
d   = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", "/path/to/nightslashers/roms")
MRA = sys.argv[1] if len(sys.argv) > 1 else \
      "/path/to/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB) FOLD.mra"
romfile = lambda nm: open(os.path.join(ROM, nm), 'rb').read()

# ---------- AUTHORITATIVE interleave2rom (port of mra2rom.go:282-360) ----------
def interleave2rom(width_bits, parts):
    # parts = [(data:bytes, mapstr:str), ...]
    width = width_bits >> 3
    fingers = []
    for data, mapstr in parts:
        step = max((int(c) - 0 for c in mapstr), default=0)  # max digit
        step = max((int(c) for c in mapstr))                 # mra2rom: step = max digit value
        fingers.append([data, mapstr, step, 0])              # [data, mapstr, step, pos]
    # sel[j] = first finger whose mapstr[j] != '0'
    sel = [0]*width
    for j in range(width):
        for k in range(len(fingers)):
            if fingers[k][1][j] != '0':
                sel[j] = k; break
    out = bytearray()
    while True:
        for j in range(width-1, -1, -1):           # jmax .. 0  (HIGH output byte first)
            f = fingers[sel[j]]
            offs = (ord(f[1][j]) - ord('1')) & 0xff
            _i=f[3]+offs; out.append(f[0][_i] if _i < len(f[0]) else 0)
        brk = False
        for f in fingers:
            f[3] += f[2]
            if f[3] >= len(f[0]): brk = True
        if brk: break
    return bytes(out)

# ---------- assemble the <rom index=0> blob the authoritative way ----------
body = re.search(r'<rom index="0"[^>]*>(.*?)</rom>', open(MRA).read(), re.S).group(1)
blob = bytearray()
TOK = re.compile(r'<interleave output="(\d+)">(.*?)</interleave>'
                 r'|<part name="([^"]+)"\s*crc="[^"]*"\s*/>'
                 r'|<part repeat="([^"]+)">\s*([0-9A-Fa-f]+)\s*</part>', re.S)
for t in TOK.finditer(body):
    if t.group(1):
        parts = [(romfile(nm), mp) for nm, mp in re.findall(r'<part name="([^"]+)"[^>]*map="([^"]*)"', t.group(2))]
        blob += interleave2rom(int(t.group(1)), parts)
    elif t.group(3):
        blob += romfile(t.group(3))
    else:
        blob += bytes([int(t.group(5),16)]) * int(t.group(4),16)
print("AUTHORITATIVE blob = 0x%X bytes" % len(blob))

# ---------- bank split + fold download remap (same as validate_fold_mra) ----------
BA2_START, BA3_START = 0x210000, 0x710000
def bank_words(start, end): return [blob[i] | (blob[i+1]<<8) for i in range(start, min(end,len(blob)), 2)]
ba2 = bank_words(BA2_START, BA3_START); ba3 = bank_words(BA3_START, len(blob))
P4BASE = 0x400000
def reorder1819(w): return (w & ~(3<<18)) | (((w>>18)&1)<<19) | (((w>>19)&1)<<18)
sd2 = {}
for w,v in enumerate(ba2): sd2[reorder1819(w) if w < 0x200000 else w] = v
sd3 = {}
for w,v in enumerate(ba3):
    sd3[(((w>>1)<<2)|(w&1)) if w<P4BASE else (((w-P4BASE)<<2)|2)] = v

# ---------- unpack helpers (mirror jtnslasher_sdram.v) ----------
def hwswap16(x): return (((x>>16)&0xff)<<24)|(((x>>24)&0xff)<<16)|((x&0xff)<<8)|((x>>8)&0xff)
def plane_permute(x): return (((x>>16)&0xff)<<24)|((x&0xff)<<16)|(((x>>24)&0xff)<<8)|((x>>8)&0xff)
def planes_word(nwi): return (sd3.get(4*nwi+1,0)<<16)|sd3.get(4*nwi,0)
def p4word(nwi):      return sd3.get(4*nwi+2,0)            # the 16-bit plane4 word
GFX4_OFF = 0x200000
def obj1_word(nwi):   return (sd2.get(GFX4_OFF+2*nwi+1,0)<<16)|sd2.get(GFX4_OFF+2*nwi,0)

# ---------- golden native (down_pass) ----------
def load_native(name):
    out={}; a=0
    for l in open(os.path.join(d,name+".hex")):
        l=l.strip()
        if not l: continue
        if l[0]=='@': a=int(l[1:],16); continue
        out[a]=int(l,16); a+=1
    return out
lo=load_native("obj0lo_native"); hi=load_native("obj0hi_native"); o1=load_native("obj1_native")
# golden 40-bit render words: plane4(8) | plane_permute(hwswap16(native_planes))
def gold_obj0(nwi): return (hi[nwi]<<32)|plane_permute(hwswap16(lo[nwi]))
def gold_obj1(nwi): return plane_permute(hwswap16(o1[nwi]))   # obj1 native, same unpack family

def chk(tag, fn, ref_keys, ref):
    bad=n=0; ex=[]
    for k in ref_keys:
        n+=1
        if fn(k)!=ref(k):
            bad+=1
            if bad<=4: ex.append("@%#x got=%010x exp=%010x"%(k,fn(k),ref(k)))
    print("  %-28s : %s (%d/%d)%s"%(tag, "PASS" if bad==0 else "FAIL", n-bad, n, ("  "+ex[0] if ex else "")))
    return bad==0

keys_o0 = sorted(set(lo)&set(hi))[:1440]
keys_o1 = sorted(o1)[:128]
print("\n=== obj0 (planes) — both have hwswap16, expect PASS (planes are compensated) ===")
chk("planes plane_permute(hwswap16)", lambda n: plane_permute(hwswap16(planes_word(n))), keys_o0, lambda n: plane_permute(hwswap16(lo[n])))

print("\n=== obj0 PLANE4 lane — CURRENT [15:8] vs swap-aware [7:0] ===")
chk("CURRENT  p4 = word[15:8]", lambda n: (p4word(n)>>8)&0xff, keys_o0, lambda n: hi[n]&0xff)
chk("SWAPFIX  p4 = word[7:0] ", lambda n:  p4word(n)    &0xff, keys_o0, lambda n: hi[n]&0xff)

print("\n=== obj1 (gfx4) — CURRENT plane_permute(no swap) vs plane_permute(hwswap16) ===")
chk("CURRENT  plane_permute(d)",          lambda n: plane_permute(obj1_word(n)),            keys_o1, lambda n: gold_obj1(n))
chk("SWAPFIX  plane_permute(hwswap16 d)", lambda n: plane_permute(hwswap16(obj1_word(n))),  keys_o1, lambda n: gold_obj1(n))
