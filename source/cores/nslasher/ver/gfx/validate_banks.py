#!/usr/bin/env python3
# Extend the 7c-3d byte-check to the banks mra_assemble.py never validated:
# snd, oki1, oki2 (BA1, identity download) + gfx1, gfx2 (BA2, raw mbh-00/01 in the
# download blob; the bit18<->19 reorder is applied by jtnslasher_dwnld RTL, separately
# proven). A wrong bank here => the cab's SDRAM has wrong bytes => a boot ROM-checksum
# of that region fails (hang) and/or the Z80/OKI reads garbage (dead sound) — while the
# idealized sim (preloaded correct ROMs) passes. Usage: python3 validate_banks.py <mra>
import os, re, sys
d   = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", os.path.join(d, "..", "..", "..", "..", "..", "fpga", "nightslashers", "roms"))
if not os.path.isdir(ROM):
    ROM = os.environ.get("ROMDIR", os.path.join(d, "..", "..", "..", "roms"))
MRA = sys.argv[1] if len(sys.argv) > 1 else os.path.join(d, "..", "..", "..", "mame-dump", "nslashers.mra")
romfile = lambda nm: open(os.path.join(ROM, nm), 'rb').read()

# ---- assemble the download blob (same loader model as mra_assemble.py) ----
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
print("MRA: %s" % os.path.basename(MRA))
print("assembled blob = 0x%X bytes (expect 0x1110000)" % len(blob))

def check_id(tag, off, romname, length=None):
    ref = romfile(romname)
    if length is None: length = len(ref)
    bad = first = None; nbad = 0
    for i in range(length):
        if blob[off + i] != ref[i]:
            nbad += 1
            if first is None: first = i
            if nbad <= 4:
                print("   %-6s mismatch @blob[%#x] (rom+%#x): got %02X ref %02X"
                      % (tag, off + i, i, blob[off + i], ref[i]))
    status = "OK" if nbad == 0 else "%d/%d BAD (first @rom+%#x)" % (nbad, length, first)
    print("  %-6s : blob@%#010x len %#x vs %-14s -> %s" % (tag, off, length, romname, status))
    return nbad == 0

print("=== BA1/BA2 bank byte-check (previously unvalidated) ===")
r = []
r.append(check_id("snd",  0x100000, "sndprg.17l"))           # 64 KB  Z80
r.append(check_id("oki1", 0x110000, "mbh-10.14l"))           # 512 KB ADPCM
r.append(check_id("oki2", 0x190000, "mbh-11.16l"))           # 512 KB ADPCM
r.append(check_id("gfx1", 0x210000, "mbh-00.8c"))            # 2 MB tiles PF1/2 (raw; reorder in dwnld)
r.append(check_id("gfx2", 0x410000, "mbh-01.9c"))            # 2 MB tiles PF3/4 (raw; reorder in dwnld)
print("=== RESULT: %s ===" % ("ALL CHECKED BANKS BYTE-EXACT" if all(r) else "MISMATCH — see above"))
