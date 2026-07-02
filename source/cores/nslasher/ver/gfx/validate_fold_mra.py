#!/usr/bin/env python3
# Validate the FOLD .mra end-to-end (build-free): assemble the download blob from the real ROMs exactly as
# the MiSTer loader would (interleave maps + fills), split into banks, apply the jtnslasher_dwnld FOLD remap,
# then confirm the resulting SDRAM image reproduces the proven native gfx:
#   obj0 (BA3): per nwi, 32b word@(nwi*2)=planes_native, low byte of word@(nwi*2+1)=plane4_native
#   obj1 (BA2): gfx4 relocated, NOT reordered, == obj1_native
#   gfx1/gfx2 (BA2): reorder still applied (unchanged) — spot-checked
# Usage: ROMDIR=.../mame-dump/roms python3 validate_fold_mra.py [foldmra]
import os, re, sys
d = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", os.path.join(d, "..", "..", "mame-dump", "roms"))
MRA = sys.argv[1] if len(sys.argv) > 1 else \
      r"/path/to/nightslashers/releases/Night Slashers (Over Sea Rev 1.2, DE-0397-0 PCB) FOLD.mra"
romfile = lambda nm: open(os.path.join(ROM, nm), 'rb').read()

# ---- assemble the blob from <rom index="0"> (interleave maps / plain parts / repeat-fills) ----
body = re.search(r'<rom index="0"[^>]*>(.*?)</rom>', open(MRA).read(), re.S).group(1)
blob = bytearray()
TOK = re.compile(r'<interleave output="(\d+)">(.*?)</interleave>'
                 r'|<part name="([^"]+)"\s*crc="[^"]*"\s*/>'
                 r'|<part repeat="([^"]+)">\s*([0-9A-Fa-f]+)\s*</part>', re.S)
for t in TOK.finditer(body):
    if t.group(1):
        outb = int(t.group(1)) // 8
        parts = [(romfile(nm), mp) for nm, mp in re.findall(r'<part name="([^"]+)"[^>]*map="([^"]*)"', t.group(2))]
        nwords = min(len(data) // sum(c != '0' for c in mp) for data, mp in parts)
        out = bytearray(nwords * outb)
        for data, mp in parts:
            order = [(p, int(c) - 1) for p, c in enumerate(mp) if c != '0']
            stride = len(order)
            for w in range(nwords):
                for outp, ib in order:
                    out[w * outb + outp] = data[w * stride + ib]
        blob += out
    elif t.group(3):
        blob += romfile(t.group(3))
    else:
        blob += bytes([int(t.group(5), 16)]) * int(t.group(4), 16)
print("assembled FOLD blob = 0x%X bytes (expect 0x1190000)" % len(blob))

# ---- fold bank byte-offsets in the blob (fold macros) ----
BA2_START = 0x210000; BA3_START = 0x710000
def bank_words(start, end):                       # 16-bit words of a blob byte-range -> {wordidx: value}
    return [blob[i] | (blob[i+1] << 8) for i in range(start, min(end, len(blob)), 2)]
ba2 = bank_words(BA2_START, BA3_START)            # BA2 = gfx1 + gfx2 + gfx4
ba3 = bank_words(BA3_START, len(blob))            # BA3 = planes + plane4 spread

# ---- jtnslasher_dwnld FOLD remap -> SDRAM image (16-bit words) ----
P4BASE = 0x400000
def reorder1819(w):  return (w & ~(3 << 18)) | (((w >> 18) & 1) << 19) | (((w >> 19) & 1) << 18)
sd2 = {}                                          # BA2 SDRAM
for w, v in enumerate(ba2):
    dst = reorder1819(w) if w < 0x200000 else w   # gfx1/gfx2 reorder ; gfx4 (>=0x200000) identity
    sd2[dst] = v
sd3 = {}                                          # BA3 SDRAM
for w, v in enumerate(ba3):
    if w < P4BASE:                                # planes: {w[hi:1],0,w[0]}
        dst = ((w >> 1) << 2) | (w & 1)
    else:                                         # plane4 spread: word(nwi) -> 4nwi+2
        dst = ((w - P4BASE) << 2) | 2
    sd3[dst] = v

# ---- read back as the engines do, compare to native golden ----
def load_native(name):
    out = {}; a = 0
    for l in open(os.path.join(d, name + ".hex")):
        l = l.strip()
        if not l: continue
        if l[0] == '@': a = int(l[1:], 16); continue
        out[a] = int(l, 16); a += 1
    return out
lo = load_native("obj0lo_native"); hi = load_native("obj0hi_native"); o1 = load_native("obj1_native")

def chk(tag, fn, ref):
    bad = n = 0
    for k, v in ref.items():
        n += 1
        if fn(k) != v:
            bad += 1
            if bad <= 3: print("   %s @%#x: got %X ref %X" % (tag, k, fn(k), v))
    print("  %-7s : %s  (%d checked, %d bad)" % (tag, "OK" if bad == 0 else "%d BAD" % bad, n, bad))
    return bad == 0

GFX4_OFF = 0x200000                                # GFX4_OFFSET (16-bit words into BA2)
ok_lo = chk("obj0 planes", lambda n: (sd3.get(4*n+1, 0) << 16) | sd3.get(4*n, 0), lo)
ok_hi = chk("obj0 plane4", lambda n: sd3.get(4*n+2, 0) & 0xFF, hi)
ok_o1 = chk("obj1 gfx4",   lambda n: (sd2.get(GFX4_OFF + 2*n + 1, 0) << 16) | sd2.get(GFX4_OFF + 2*n, 0), o1)

print("=== RESULT: %s ===" % ("FOLD .mra BYTE-EXACT (planes + plane4 + relocated gfx4 all correct)"
                              if all([ok_lo, ok_hi, ok_o1]) else "MISMATCH — see above"))
sys.exit(0 if all([ok_lo, ok_hi, ok_o1]) else 1)
