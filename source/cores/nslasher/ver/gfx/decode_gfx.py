#!/usr/bin/env python3
# M3a — Night Slashers gfx decryption (deco56/deco74) + tile decode, validation tool.
#
# Faithful port of MAME decocrpt.c deco_decrypt() + the nslasher DRIVER_INIT bitplane
# reorder + the gfx_layout tile decode. Descrambles the REAL gfx ROMs and renders a tile
# sheet PNG so the decrypt can be eyeball-validated (recognizable graphics == correct).
#
#   gfx1 = mbh-00.8c (2MB) -> reorder -> deco56 -> charlayout 8x8 / tilelayout 16x16 (PF1/2)
#   gfx2 = mbh-01.9c (2MB) -> reorder -> deco74 -> tilelayout 16x16 (PF3/4)
#
# Tables are PARSED straight from doc/decocrpt.c (no transcription). Stdlib only.
#
# Usage: python3 decode_gfx.py <romdir> <decocrpt.c> [outdir]
import sys, os, re, zlib, struct

romdir   = sys.argv[1] if len(sys.argv) > 1 else "/path/to/nightslashers/roms"
crpt     = sys.argv[2] if len(sys.argv) > 2 else "../../doc/decocrpt.c"
outdir   = sys.argv[3] if len(sys.argv) > 3 else "."

# ---- parse all `static const UINTxx name[...] = { ... };` arrays from decocrpt.c ----
def parse_c_arrays(path):
    txt = open(path).read()
    txt = re.sub(r'/\*.*?\*/', '', txt, flags=re.S)   # strip block comments
    out = {}
    for m in re.finditer(r'(?:static\s+)?const\s+\w+\s+(\w+)\s*(\[[^\]]*\])+\s*=\s*\{(.*?)\};', txt, re.S):
        name, body = m.group(1), m.group(3)
        nums = re.findall(r'0x[0-9a-fA-F]+|\d+', body)
        out[name] = [int(x, 0) for x in nums]
    return out

T = parse_c_arrays(crpt)
xor_masks     = T['xor_masks']                 # 16
swap_patterns = [T['swap_patterns'][i*16:(i+1)*16] for i in range(8)]   # 8 x 16
for tag in ('deco56_xor_table','deco56_address_table','deco56_swap_table',
            'deco74_xor_table','deco74_address_table','deco74_swap_table'):
    assert len(T[tag]) == 0x800, "%s len=%d" % (tag, len(T[tag]))
assert len(xor_masks) == 16 and len(swap_patterns) == 8

def bitswap16(v, pat):     # pat[0] -> result bit15 (MAME BITSWAP16, MSB first)
    r = 0
    for i, b in enumerate(pat):
        if (v >> b) & 1:
            r |= 1 << (15 - i)
    return r

# deco_decrypt: region as BIG-ENDIAN 16-bit words (the tables were derived on 68000/BE hw),
# 0x800-word blocks.
#   out[i] = BITSWAP16( in[addr] ^ xor_masks[xor_table[addr&0x7ff]], swap_patterns[swap_table[i&0x7ff]] )
#   where addr = (i & ~0x7ff) | address_table[i&0x7ff]
def deco_decrypt(data, xor_table, address_table, swap_table):
    n = len(data) // 2
    words = [(data[2*i] << 8) | data[2*i+1] for i in range(n)]   # big-endian
    out = [0] * n
    for i in range(n):
        lo = i & 0x7ff
        addr = (i & ~0x7ff) | address_table[lo]
        src = words[addr]
        x = xor_masks[xor_table[addr & 0x7ff]]
        out[i] = bitswap16(src ^ x, swap_patterns[swap_table[lo]])
    b = bytearray(n * 2)
    for i, w in enumerate(out):
        b[2*i]   = (w >> 8) & 0xff      # big-endian write-back
        b[2*i+1] = w & 0xff
    return bytes(b)

# nslasher DRIVER_INIT: swap the 0x80000 chunks at 0x80000 <-> 0x100000, then decrypt.
def nslasher_reorder(data):
    d = bytearray(data)
    a, b = 0x80000, 0x100000
    d[a:a+0x80000], d[b:b+0x80000] = data[b:b+0x80000], data[a:a+0x80000]
    return bytes(d)

# ---- generic MAME planar tile decode ----
def decode_tile(region, base_bit, planes, planeoff, xoff, yoff, w, h):
    px = [[0]*w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            v = 0
            for p in range(planes):
                bit = base_bit + planeoff[p] + yoff[y] + xoff[x]
                b = (region[bit >> 3] >> (7 - (bit & 7))) & 1
                v |= b << (planes - 1 - p)
            px[y][x] = v
    return px

def charlayout_8x8(region):
    half = (len(region) * 8) // 2          # RGN_FRAC(1,2)
    return dict(planes=4, planeoff=[half+8, half, 8, 0],
                xoff=[0,1,2,3,4,5,6,7], yoff=[i*16 for i in range(8)],
                inc=16*8, w=8, h=8, count=(len(region)//2)//16)

def tilelayout_16x16(region):
    half = (len(region) * 8) // 2
    return dict(planes=4, planeoff=[half+8, half, 8, 0],
                xoff=[32*8+i for i in range(8)] + [i for i in range(8)],
                yoff=[i*16 for i in range(16)],
                inc=64*8, w=16, h=16, count=(len(region)//2)//64)

# ---- minimal PNG (RGB, stdlib) ----
def write_png(path, w, h, rows):   # rows: list of bytearray, each w*3 bytes
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t+d) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) +
                chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

GRAY = [(v*17, v*17, v*17) for v in range(16)]     # 4bpp value -> grayscale

def tilesheet_png(path, region, lay, cols, rows_t, first=0):
    w, h = lay['w'], lay['h']
    W, H = cols*w, rows_t*h
    img = [bytearray(W*3) for _ in range(H)]
    for ti in range(cols*rows_t):
        t = first + ti
        if t >= lay['count']:
            break
        px = decode_tile(region, t*lay['inc'], lay['planes'], lay['planeoff'],
                         lay['xoff'], lay['yoff'], w, h)
        ox, oy = (ti % cols)*w, (ti // cols)*h
        for y in range(h):
            for x in range(w):
                r, g, b = GRAY[px[y][x]]
                o = (ox + x)*3
                img[oy+y][o:o+3] = bytes((r, g, b))
    write_png(path, W, H, img)
    print("  wrote %s (%dx%d, %d tiles from #%d)" % (path, W, H, cols*rows_t, first))

def process(tag, romfile, xt, at, st):
    raw = open(os.path.join(romdir, romfile), 'rb').read()
    print("%s: %s (%d bytes)" % (tag, romfile, len(raw)))
    dec = deco_decrypt(nslasher_reorder(raw), xt, at, st)
    open(os.path.join(outdir, tag + "_dec.bin"), 'wb').write(dec)
    return dec

g1 = process("gfx1", "mbh-00.8c", T['deco56_xor_table'], T['deco56_address_table'], T['deco56_swap_table'])
g2 = process("gfx2", "mbh-01.9c", T['deco74_xor_table'], T['deco74_address_table'], T['deco74_swap_table'])

# Eyeball checks: gfx1 8x8 chars (font, very recognizable) + gfx1/gfx2 16x16 tiles.
tilesheet_png(os.path.join(outdir, "gfx1_chars.png"), g1, charlayout_8x8(g1), 64, 64, first=0)
tilesheet_png(os.path.join(outdir, "gfx1_tiles.png"), g1, tilelayout_16x16(g1), 32, 32, first=0)
tilesheet_png(os.path.join(outdir, "gfx2_tiles.png"), g2, tilelayout_16x16(g2), 32, 32, first=0)
print("done. eyeball the PNGs: recognizable graphics => deco56/deco74 decrypt is correct.")
