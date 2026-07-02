#!/usr/bin/env python3
# Decode a PROBE #3 (gfx-fetch) overlay read. Given the captured PF1 render-word address (cap_addr,
# chars8), compute what the gfxdec SHOULD produce + the raw SDRAM words it should read, from the
# down_pass golden. Compare against the values read off the cab overlay.
#   usage: gfx_golden.py <cap_addr_hex> [cap_dec_hex] [cap_sdaddr_hex] [cap_sddata_hex]
import os, sys
d = os.path.dirname(os.path.abspath(__file__))

def load_hex_words(fn):           # one hex word per line (r1_gfx1.hex = SDRAM 16-bit words)
    return [int(l,16) for l in open(os.path.join(d,fn)) if l.strip()]
def load_tab(fn):                 # deco table, one hex per line
    return [int(l,16) for l in open(os.path.join(d,fn)) if l.strip()]

cap_addr = int(sys.argv[1],0)
got_dec    = int(sys.argv[2],0) if len(sys.argv)>2 else None
got_sdaddr = int(sys.argv[3],0) if len(sys.argv)>3 else None
got_sddata = int(sys.argv[4],0) if len(sys.argv)>4 else None

addr_tab = load_tab("deco56_address.hex")           # 11-bit permuted source low-addr
r1       = load_hex_words("r1_gfx1.hex")            # SDRAM golden (reorder(mbh-00)) 16-bit BE words
chars8   = open(os.path.join(d,"gfx1_chars8.bin"),'rb').read()

# gfxdec: W = rom_addr (chars8). two reads: a1={0,W[18:11],ta}, a2={1,W[18:11],ta}; ta=addr_tab[W&0x7ff]
W   = cap_addr
ta  = addr_tab[W & 0x7ff]
hi  = (W >> 11) & 0xff            # W[18:11]
a1  = (hi << 11) | ta             # bit19=0
a2  = (1 << 19) | (hi << 11) | ta # bit19=1  (W + 0x80000 read; this is the LAST read the probe captures)
sd1 = r1[a1] if a1 < len(r1) else None
sd2 = r1[a2] if a2 < len(r1) else None
# golden decrypted render word (render-format .bin, 32-bit LE)
o = cap_addr*4
dec_golden = chars8[o] | (chars8[o+1]<<8) | (chars8[o+2]<<16) | (chars8[o+3]<<24)

def bsw16(v): return ((v&0xff)<<8)|(v>>8)
print("cap_addr  = 0x%05X  (W=0x%05X, ta=0x%03X, W[18:11]=0x%02X)" % (cap_addr,W,ta,hi))
print("GOLDEN cap_dec    = 0x%08X" % dec_golden)
print("GOLDEN cap_sdaddr = 0x%05X (read2 = W+0x80000)   [read1 a1=0x%05X]" % (a2,a1))
print("GOLDEN cap_sddata = 0x%04X (raw r1_gfx1[a2])      [read1 sd1=0x%04X]" % (sd2 if sd2 is not None else 0, sd1 if sd1 is not None else 0))
print("  (byteswap16 of cap_sddata = 0x%04X)" % bsw16(sd2 if sd2 is not None else 0))
if got_dec is not None:
    print("READ   cap_dec    = 0x%08X  -> %s" % (got_dec, "MATCH" if got_dec==dec_golden else "MISMATCH"))
if got_sdaddr is not None:
    print("READ   cap_sdaddr = 0x%05X  -> %s" % (got_sdaddr, "MATCH" if got_sdaddr==a2 else "MISMATCH (addr path!)"))
if got_sddata is not None:
    tag = "MATCH" if got_sddata==sd2 else ("BYTESWAP16" if got_sddata==bsw16(sd2) else "MISMATCH")
    print("READ   cap_sddata = 0x%04X  -> %s" % (got_sddata, tag))
