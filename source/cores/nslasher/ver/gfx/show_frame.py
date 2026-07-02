#!/usr/bin/env python3
# Convert the 7e live-captured framebuffer (frame_game.hex, 240x384, 0xBBGGRR/pixel) to PNG.
# tb_game wrote fb = {blue,green,red}; visible region is the first 320 columns.
import os, zlib, struct
d = os.path.dirname(os.path.abspath(__file__))
W, H = 384, 240

def write_png(path, w, h, rows):
    def ch(t, b): return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n'
        + ch(b'IHDR', struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + ch(b'IDAT', zlib.compress(raw, 9)) + ch(b'IEND', b''))

vals = [int(l.strip(), 16) for l in open(os.path.join(d, "frame_game.hex")) if l.strip()]
nz = 0
rows = []
for y in range(H):
    r = bytearray(W * 3)
    for x in range(W):
        h = vals[y * W + x]
        if h:
            nz += 1
        r[x*3] = h & 0xff            # R
        r[x*3+1] = (h >> 8) & 0xff   # G
        r[x*3+2] = (h >> 16) & 0xff  # B
    rows.append(r)
write_png(os.path.join(d, "frame_game.png"), W, H, rows)

# also a 320-wide crop (drop blanking columns) for a clean view
crop = [bytes(r[:320*3]) for r in rows]
write_png(os.path.join(d, "frame_game_320.png"), 320, H, crop)
print("frame_game.png %dx%d / frame_game_320.png 320x%d  nonzero=%d" % (W, H, H, nz))
