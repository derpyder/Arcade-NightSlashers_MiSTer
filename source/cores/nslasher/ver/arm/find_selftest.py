#!/usr/bin/env python3
# Static analysis of the decrypted ARM ROM (dec.bin) to locate boot self-test
# routines + their halt loops + the IO/RAM base constants they reference.
#
# Strategy: the digit ERROR screen draws chars into PF1 text RAM (0x182000) and
# halts in a tight `B .` loop. MAME passes the test so it never runs that code,
# and our boot-sim passes too -> the routine is invisible at runtime. So find it
# statically: (1) every `B .` self-loop, (2) every `ldr rX,[pc,#imm]` that loads a
# constant in the video/IO/work-RAM ranges, so we can objdump the routine around it.
import struct, sys

data = open('dec.bin','rb').read()
W = struct.unpack('<%dI' % (len(data)//4), data)
N = len(W)
def A(w): return w*4

# ---- 1) self-branch infinite loops (b .  == 0xEAFFFFFE) ----
print("=== self-loops  b .  (cond=AL) ===")
selfloops=[]
for w in range(N):
    if W[w]==0xEAFFFFFE:
        selfloops.append(w); print("  %06x: b ." % A(w))
# conditional self-loops (b{cond} .) cond!=AL/NV, branch op 0xXA, offset 0xFFFFFE
print("=== conditional self-loops  b{cond} .  ===")
for w in range(N):
    v=W[w]
    if (v & 0x0FFFFFFF)==0x0AFFFFFE and (v>>28)!=0xE and (v>>28)!=0xF:
        print("  %06x: b{cc=%x} ." % (A(w), v>>28))

# ---- 2) pc-relative LDR of interesting base constants ----
# ldr rX,[pc,#±imm] word load: (v & 0x0F7F0000)==0x051F0000
def is_ldr_pc(v): return (v & 0x0F7F0000)==0x051F0000
def ldr_lit_word(w):
    v=W[w]; imm=v & 0xFFF; U=(v>>23)&1
    litbyte = A(w)+8 + (imm if U else -imm)
    return litbyte>>2
# interesting ranges (byte addresses of the constant VALUE the code loads)
def cls(val):
    if 0x180000<=val<0x18a000: return "PF1/2 data (text!)"
    if 0x1c0000<=val<0x1ca000: return "PF3/4 data"
    if 0x168000<=val<0x16a000: return "palette"
    if 0x163000<=val<0x163100: return "Ace RAM"
    if 0x190000<=val<0x196000: return "PF rowscroll"
    if 0x140000<=val<0x140010: return "VBL ack"
    if 0x150000<=val<0x150010: return "EEPROM/pri"
    if 0x170000<=val<0x17e000: return "spriteram"
    if 0x200000<=val<0x201000: return "104 prot/soundlatch"
    if 0x100000<=val<0x120000: return "WORK RAM"
    if 0x000000<=val<0x100000: return "main ROM"
    return None
print("\n=== code that loads an IO/RAM/ROM base via ldr rX,[pc] ===")
hits={}
for w in range(N):
    if not is_ldr_pc(W[w]): continue
    lit=ldr_lit_word(w)
    if not (0<=lit<N): continue
    val=W[lit]
    c=cls(val)
    if c is None: continue
    rd=(W[w]>>12)&0xF
    hits.setdefault(c,[]).append((A(w),rd,val,A(lit)))
# print, but cap per-class to keep readable; highlight text/palette/work-ram
order=["PF1/2 data (text!)","palette","WORK RAM","Ace RAM","104 prot/soundlatch",
       "VBL ack","EEPROM/pri","spriteram","PF3/4 data","PF rowscroll","main ROM"]
for c in order:
    if c not in hits: continue
    lst=hits[c]
    print("\n-- %s  (%d sites) --" % (c, len(lst)))
    cap = 40 if "text" in c or c in ("palette","WORK RAM","104 prot/soundlatch") else 12
    for (ia,rd,val,la) in lst[:cap]:
        print("   %06x: ldr r%-2d = %08x   (lit@%06x)" % (ia,rd,val,la))
    if len(lst)>cap: print("   ... (%d more)" % (len(lst)-cap))
