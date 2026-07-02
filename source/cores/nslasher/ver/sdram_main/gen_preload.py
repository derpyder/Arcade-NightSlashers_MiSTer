#!/usr/bin/env python3
# Emit sdram_bank1.hex preloaded with the CORRECT little-endian SDRAM image
# for a window of ARM words, exactly as the (verified) download SHOULD store it:
#   SDRAM[2i]   = raw[i] & 0xFFFF       (low  half = bytes b1 b0)
#   SDRAM[2i+1] = (raw[i] >> 16)        (high half = bytes b3 b2)
# This isolates the READ path: if the real jtframe_sdram64+bcache returns
# byteswap32(raw) from this CORRECT image, the bug is in the read assembly.
import os
D   = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", os.path.join(D, "..","..","..","..","..","roms"))
a = open(os.path.join(ROM,"ly-00.1f"),"rb").read()
b = open(os.path.join(ROM,"ly-01.2f"),"rb").read()
n = len(a)//2
def raw(i): return (a[2*i]|(a[2*i+1]<<8)) | ((b[2*i]|(b[2*i+1]<<8))<<16)

windows = [(0x000000,0x000020), (0x0235F0,0x023620)]  # reset region + the LUT-overrun word 0x023608
lines=[]
for lo,hi in windows:
    lines.append("@%06X"%(2*lo))           # 16-bit SDRAM word address of word lo's low half
    for i in range(lo,hi):
        w=raw(i)
        lines.append("%04X"%(w&0xffff))     # SDRAM[2i]   low half
        lines.append("%04X"%((w>>16)&0xffff))# SDRAM[2i+1] high half
open(os.path.join(D,"sdram_bank1.hex"),"w").write("\n".join(lines)+"\n")
print("wrote sdram_bank1.hex; golden raw[0x023608]=0x%08X (SDRAM[0x046C10]=%04X SDRAM[0x046C11]=%04X)"
      %(raw(0x023608), raw(0x023608)&0xffff, raw(0x023608)>>16))
print("golden raw[0x000000]=0x%08X  raw[0x023609]=0x%08X"%(raw(0),raw(0x023609)))
