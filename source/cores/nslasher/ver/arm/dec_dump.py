#!/usr/bin/env python3
# Decrypt the REAL nslasher main ROM (deco156) and emit a flat little-endian binary
# (dec.bin) for objdump, plus print a requested word range. Combines make_rom.py's
# ROM_LOAD32_WORD interleave with gold.py's deco156 decrypt() (port of MAME machine/deco156.c).
#
# Usage: python3 dec_dump.py <prog.1f> <prog.2f> [lo_word hi_word]
import sys

p1f, p2f = sys.argv[1], sys.argv[2]
lo = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x2f0
hi = int(sys.argv[4], 0) if len(sys.argv) > 4 else 0x305

a = open(p1f, 'rb').read()
b = open(p2f, 'rb').read()
N = len(a) // 2                       # 0x40000 words
src = [(a[2*i] | (a[2*i+1] << 8)) | ((b[2*i] | (b[2*i+1] << 8)) << 16) for i in range(N)]

addrx = [0xce4a,0x4db2,0xef60,0x5737,0x13dc,0x4bd9,0xa209,0xd996,
         0xa700,0xeca0,0x7529,0x3100,0x33b4,0x6161,0x1eef,0xf5a5]
datax = [(2,0x04400000),(3,0x40000004),(4,0x00048000),(5,0x00000280),
         (6,0x00200040),(7,0x09000000),(8,0x00001100),(9,0x20002000),
         (10,0x00000022),(11,0x000a0000),(12,0x10004000),(13,0x00010400),
         (14,0x80000010),(15,0x00000009),(16,0x02100000),(17,0x00800800)]
consts = [0xec63197a,0x58a5a55f,0xe3a65f16,0x28d93783]
ords = [
 [1,4,7,28,22,18,20,9,16,10,30,2,31,24,19,29,6,21,23,11,12,13,5,0,8,26,27,15,14,17,25,3],
 [14,23,28,29,6,24,10,1,5,16,7,2,30,8,18,3,31,22,25,20,17,0,19,27,9,12,21,15,26,13,4,11],
 [19,30,21,4,2,18,15,1,12,25,8,0,24,20,17,23,22,26,28,16,9,27,6,11,31,10,3,13,14,7,29,5],
 [30,6,15,0,31,18,26,22,14,23,19,17,10,8,11,20,1,28,2,4,9,24,25,27,7,21,13,29,5,3,16,12]]

def bitswap32(v, order):
    r = 0
    for i, bbit in enumerate(order):
        if (v >> bbit) & 1:
            r |= 1 << (31 - i)
    return r

dst = [0]*N
for w in range(N):
    addr = (w & 0xff0000) | 0x92c6
    for i in range(16):
        if w & (1 << i):
            addr ^= addrx[i]
    dword = src[addr]
    for bit, mask in datax:
        if w & (1 << bit):
            dword ^= mask
    c = w & 3
    dword = bitswap32(dword ^ consts[c], ords[c])
    dst[w] = dword

with open('dec.bin', 'wb') as f:
    for w in dst:
        f.write(bytes([w & 0xff, (w >> 8) & 0xff, (w >> 16) & 0xff, (w >> 24) & 0xff]))

print("wrote dec.bin (%d words). decrypted words 0x%x..0x%x (byte addr = word*4):" % (N, lo, hi))
for w in range(lo, hi+1):
    print("  %06x: %08x" % (w*4, dst[w]))
