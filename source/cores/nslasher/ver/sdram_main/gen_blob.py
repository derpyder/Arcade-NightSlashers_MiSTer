#!/usr/bin/env python3
# Emit blob.hex = the little-endian download byte stream for ARM words [BASE_W, BASE_W+NW),
# one byte per line (index k -> byte at ioctl_addr = BASE_W*4 + k). This is exactly what the
# MRA/ioctl delivers for BA1 (validate_banks.py confirmed the loader delivers these bytes).
import os
D   = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", os.path.join(D,"..","..","..","..","..","roms"))
a = open(os.path.join(ROM,"ly-00.1f"),"rb").read()
b = open(os.path.join(ROM,"ly-01.2f"),"rb").read()
def raw(i): return (a[2*i]|(a[2*i+1]<<8)) | ((b[2*i]|(b[2*i+1]<<8))<<16)
BASE_W=0x023600; NW=0x40
out=[]
for i in range(BASE_W, BASE_W+NW):
    w=raw(i)
    for j in range(4):
        out.append("%02X"%((w>>(8*j))&0xff))   # little-endian byte order b0,b1,b2,b3
open(os.path.join(D,"blob.hex"),"w").write("\n".join(out)+"\n")
print("wrote blob.hex: %d bytes, BASE_W=0x%06X BASE_BYTE=0x%06X"%(len(out),BASE_W,BASE_W*4))
print("golden raw[0x023608]=0x%08X"%raw(0x023608))
