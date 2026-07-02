#!/usr/bin/env python3
# 7c-3d byte-check: assemble the jframe-generated .mra from the REAL ROMs exactly as the MiSTer ROM
# loader would (interleave maps + plain parts + FF fills), then verify each SDRAM bank reproduces the
# proven golden: main == raw_rom.hex, obj0lo/obj0hi/obj1 == *_native.hex. This closes the loop the 7e
# sim never ran (it loaded pre-split native hex). Usage: ROMDIR=.../roms python3 mra_assemble.py [mra]
import os, re, sys
d = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", os.path.join(d, "..", "..", "..", "roms"))
MRA = sys.argv[1] if len(sys.argv) > 1 else os.path.join(d, "..", "..", "..", "mame-dump", "nslashers.mra")
romfile = lambda nm: open(os.path.join(ROM, nm), 'rb').read()

# ---- assemble the download blob from the <rom index="0"> body, token by token, in order ----
body = re.search(r'<rom index="0"[^>]*>(.*?)</rom>', open(MRA).read(), re.S).group(1)
blob = bytearray()
TOK = re.compile(r'<interleave output="(\d+)">(.*?)</interleave>'
                 r'|<part name="([^"]+)"\s*crc="[^"]*"\s*/>'
                 r'|<part repeat="([^"]+)">\s*([0-9A-Fa-f]+)\s*</part>', re.S)
for t in TOK.finditer(body):
    if t.group(1):                                   # <interleave output=N>
        outb = int(t.group(1)) // 8
        parts = [(romfile(nm), mp) for nm, mp in re.findall(r'<part name="([^"]+)"[^>]*map="([^"]*)"', t.group(2))]
        nwords = min(len(data) // sum(c != '0' for c in mp) for data, mp in parts)
        out = bytearray(nwords * outb)
        for data, mp in parts:
            order = [(p, int(c) - 1) for p, c in enumerate(mp) if c != '0']   # (out-byte-pos, in-byte-idx)
            stride = len(order)
            for w in range(nwords):
                for outp, ib in order:
                    out[w * outb + outp] = data[w * stride + ib]
        blob += out
    elif t.group(3):                                 # plain <part name>
        blob += romfile(t.group(3))
    else:                                            # <part repeat=K> FILL
        blob += bytes([int(t.group(5), 16)]) * int(t.group(4), 16)
print("assembled blob = 0x%X bytes (expect 0x1110000)" % len(blob))

# ---- bank offsets in the blob (macros.def) ; dwnld: BA1/BA3 identity, BA2 reorder (handled below) ----
word32 = lambda off: blob[off] | (blob[off+1] << 8) | (blob[off+2] << 16) | (blob[off+3] << 24)

def load_native(name):
    out = {}; a = 0
    for l in open(os.path.join(d, name + ".hex")):
        l = l.strip()
        if not l: continue
        if l[0] == '@': a = int(l[1:], 16); continue
        out[a] = int(l, 16); a += 1
    return out

def check(tag, got_fn, ref, lim=None):
    bad = mn = 0
    items = ref.items() if isinstance(ref, dict) else enumerate(ref)
    for k, v in items:
        if lim and mn >= lim: break
        mn += 1
        g = got_fn(k)
        if g != v:
            bad += 1
            if bad <= 3: print("   %s mismatch @%#x: got %08X ref %08X" % (tag, k, g, v))
    print("  %-8s : %s  (%d checked, %d bad)" % (tag, "OK" if bad == 0 else "%d BAD" % bad, mn, bad))
    return bad == 0

print("=== bank byte-check (assembled .mra vs golden) ===")
# main ARM ROM: BA1 @0x000000, 32-bit, identity. raw_rom.hex = one %08x word per line.
raw = [int(l, 16) for l in open(os.path.join(d, "raw_rom.hex")) if l.strip()]
ok_main = check("main", lambda i: word32(0x000000 + i*4), raw, lim=len(raw))
# sprites: BA3 identity. obj0lo @0x610000 (32b word@nwi*4); obj0hi @0xE10000 (byte@nwi); obj1 @0x1010000 (32b).
lo = load_native("obj0lo_native"); hi = load_native("obj0hi_native"); o1 = load_native("obj1_native")
ok_lo = check("obj0lo", lambda n: word32(0x610000 + n*4), lo)
ok_hi = check("obj0hi", lambda n: blob[0xE10000 + n],     hi)
ok_o1 = check("obj1",   lambda n: word32(0x1010000 + n*4), o1)
print("=== RESULT: %s ===" % ("ALL BANKS BYTE-EXACT" if all([ok_main, ok_lo, ok_hi, ok_o1]) else "MISMATCH — see above"))
