#!/usr/bin/env python3
# Diagnostic: figure out the correct deco56 gfx pipeline by trying combos + a structure metric.
import sys, os, re, zlib, struct
romdir = "/path/to/nightslashers/roms"
crpt   = "/path/to/nightslashers/jtcores/cores/nslasher/doc/decocrpt.c"
outdir = "/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx"

def parse_c_arrays(path):
    txt = re.sub(r'/\*.*?\*/', '', open(path).read(), flags=re.S)
    out = {}
    for m in re.finditer(r'(?:static\s+)?const\s+\w+\s+(\w+)\s*(?:\[[^\]]*\])+\s*=\s*\{(.*?)\};', txt, re.S):
        out[m.group(1)] = [int(x,0) for x in re.findall(r'0x[0-9a-fA-F]+|\d+', m.group(2))]
    return out
T = parse_c_arrays(crpt)
xor_masks = T['xor_masks']
swp = [T['swap_patterns'][i*16:(i+1)*16] for i in range(8)]
xt, at, st = T['deco56_xor_table'], T['deco56_address_table'], T['deco56_swap_table']
print("parse: xor_masks=%d swap_patterns=%d xor_table=%d address_table=%d swap_table=%d"
      % (len(xor_masks), len(T['swap_patterns']), len(xt), len(at), len(st)))
print("  xor_masks[:4]=%s  address_table[:8]=%s (max=%#x)  xor_table[:8]=%s (max=%d)  swap_table[:8]=%s (max=%d)"
      % ([hex(v) for v in xor_masks[:4]], [hex(v) for v in at[:8]], max(at), xt[:8], max(xt), st[:8], max(st)))

def bitswap16(v, pat):
    r = 0
    for i,b in enumerate(pat):
        if (v>>b)&1: r |= 1<<(15-i)
    return r
def decrypt(data, be):
    n = len(data)//2
    if be: words = [(data[2*i]<<8)|data[2*i+1] for i in range(n)]
    else:  words = [data[2*i]|(data[2*i+1]<<8) for i in range(n)]
    out = bytearray(n*2)
    for i in range(n):
        lo = i & 0x7ff
        addr = (i & ~0x7ff) | at[lo]
        w = bitswap16(words[addr] ^ xor_masks[xt[addr & 0x7ff]], swp[st[lo]])
        if be: out[2*i]=(w>>8)&0xff; out[2*i+1]=w&0xff
        else:  out[2*i]=w&0xff;      out[2*i+1]=(w>>8)&0xff
    return bytes(out)
def reorder(data):
    d=bytearray(data); a,b=0x80000,0x100000
    d[a:a+0x80000],d[b:b+0x80000]=data[b:b+0x80000],data[a:a+0x80000]; return bytes(d)

def decode_char(region, t):     # charlayout 8x8 4bpp, RGN_FRAC(1,2)
    half=(len(region)*8)//2; po=[half+8,half,8,0]; base=t*128
    px=[]
    for y in range(8):
        for x in range(8):
            v=0
            for p in range(4):
                bit=base+po[p]+y*16+x
                v|=((region[bit>>3]>>(7-(bit&7)))&1)<<(3-p)
            px.append(v)
    return px
def zero_frac(region, ntiles=2000):
    z=tot=0
    for t in range(ntiles):
        for v in decode_char(region,t):
            tot+=1
            if v==0: z+=1
    return z/tot

raw = open(os.path.join(romdir,"mbh-00.8c"),'rb').read()
variants = {
  "raw":            raw,
  "reorder_only":   reorder(raw),
  "dec_LE":         decrypt(raw, False),
  "dec_BE":         decrypt(raw, True),
  "reorder_decLE":  decrypt(reorder(raw), False),
  "reorder_decBE":  decrypt(reorder(raw), True),
  "decLE_reorder":  reorder(decrypt(raw, False)),
}
print("\nstructure (zero-pixel fraction over first 2000 8x8 chars; noise~0.06, graphics>>0.2):")
for k,v in variants.items():
    print("  %-16s %.3f" % (k, zero_frac(v)))
