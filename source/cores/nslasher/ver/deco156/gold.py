#!/usr/bin/env python3
# Golden reference for the deco156 ARM decrypt — direct port of MAME machine/deco156.c
# decrypt(). Generates raw.hex (encrypted/source ROM) + gold.hex (decrypted), 32-bit
# words, for tb_deco156.v to check the RTL against (bit-exact, full coverage).
import random
random.seed(1)
N = 0x40000  # 256K words = 1 MB (full nslasher maincpu region; exercises page bits a[16:17])
src = [random.getrandbits(32) for _ in range(N)]

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

def bitswap32(v, order):          # order[0] -> result bit31 (MAME BITSWAP32 MSB-first)
    r = 0
    for i, b in enumerate(order):
        if (v >> b) & 1:
            r |= 1 << (31 - i)
    return r

dst = [0]*N
for a in range(N):
    addr = (a & 0xff0000) | 0x92c6
    for i in range(16):
        if a & (1 << i):
            addr ^= addrx[i]
    dword = src[addr]
    for bit, mask in datax:
        if a & (1 << bit):
            dword ^= mask
    c = a & 3
    dword = bitswap32(dword ^ consts[c], ords[c])
    dst[a] = dword

with open('raw.hex','w')  as f: f.write('\n'.join('%08x'%x for x in src)+'\n')
with open('gold.hex','w') as f: f.write('\n'.join('%08x'%x for x in dst)+'\n')
print("wrote raw.hex + gold.hex, N=0x%x words"%N)
