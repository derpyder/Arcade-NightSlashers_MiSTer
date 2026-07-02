#!/usr/bin/env python3
# Interleave the two Night Slashers main-program ROMs (MAME ROM_LOAD32_WORD) into a
# raw 1 MB 32-bit-word image. The image is the ENCRYPTED ROM; jtnslasher_deco156
# descrambles it at fetch. Output: raw_rom.hex (262144 lines of %08x), for tb_boot.v.
#
#   nslasher  : mainprg.1f (offset 0, low 16) + mainprg.2f (offset 2, high 16)
#   nslasherj : lx-00.1f + lx-01.2f      nslashers: ly-00.1f + ly-01.2f
#   word[i] = (le16(2f,i) << 16) | le16(1f,i)
#
# Usage: python3 make_rom.py <prog.1f> <prog.2f> [out=raw_rom.hex]
import sys
p1f, p2f = sys.argv[1], sys.argv[2]
out = sys.argv[3] if len(sys.argv) > 3 else "raw_rom.hex"
a = open(p1f, 'rb').read()
b = open(p2f, 'rb').read()
if len(a) != 0x80000 or len(b) != 0x80000:
    sys.exit("expected 512 KB each; got %d and %d bytes" % (len(a), len(b)))
n = len(a) // 2  # 0x40000 32-bit words
with open(out, 'w') as f:
    for i in range(n):
        lo = a[2*i] | (a[2*i+1] << 8)
        hi = b[2*i] | (b[2*i+1] << 8)
        f.write('%08x\n' % (((hi << 16) | lo) & 0xffffffff))
print("wrote %s : %d 32-bit words (1 MB), from %s + %s" % (out, n, p1f, p2f))
