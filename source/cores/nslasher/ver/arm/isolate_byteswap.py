#!/usr/bin/env python3
# Does the on-cab measurement UNIQUELY imply a byteswap, or can other mechanisms fit?
#
# The overlay only ever measured 24 bits directly:
#     Row B = raw word read  & 0xFFFFFF = 0xB00E17
#     Row C = deco156-decrypt(at fetch addr) & 0xFFFFFF = 0xF499FD
# The "byteswap32" conclusion is INFERRED. This script tests whether that inference
# is forced, by enumerating every R consistent with the 24 measured bits and seeing
# which physical story each one corresponds to.
#
# Run:  cd ver/arm ; python isolate_byteswap.py
import os

D   = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", os.path.join(D, "..", "..", "..", "..", "..", "roms"))

ARM_BYTE  = 0x095050
ARM_WORD  = ARM_BYTE >> 2          # 0x25414  -- the address whose decrypt params apply
GOLDEN    = 0x170EB025             # correct raw SDRAM word at the scrambled addr
MEAS_RAW  = 0xB00E17               # Row B (low 24 of what the cab read)
MEAS_DEC  = 0xF499FD               # Row C (low 24 of decrypt of what the cab read)

# ---- deco156 DATA stages (address-scramble already done; we feed R as the source) ----
datax  = [(2,0x04400000),(3,0x40000004),(4,0x00048000),(5,0x00000280),
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

def decrypt_data(w, dword):
    """deco156 minus the address scramble: data-XOR + final bitswap/const, keyed by addr w."""
    for bit, mask in datax:
        if w & (1 << bit):
            dword ^= mask
    c = w & 3
    return bitswap32(dword ^ consts[c], ords[c]) & 0xFFFFFFFF

def byteswap32(v):
    return ((v & 0xff) << 24) | ((v & 0xff00) << 8) | ((v >> 8) & 0xff00) | ((v >> 24) & 0xff)

# ---- sanity: the golden word must decrypt to 0x..B7E7EB (handoff's "correct decrypt") ----
g_dec = decrypt_data(ARM_WORD, GOLDEN)
print("addr ARM_WORD=0x%05X" % ARM_WORD)
print("golden raw 0x%08X -> decrypt 0x%08X (low24 0x%06X; handoff says 0xB7E7EB)"
      % (GOLDEN, g_dec, g_dec & 0xFFFFFF))
bs = byteswap32(GOLDEN)
bs_dec = decrypt_data(ARM_WORD, bs)
print("byteswap   0x%08X -> decrypt 0x%08X (low24 0x%06X; handoff says cab got 0xF499FD)"
      % (bs, bs_dec, bs_dec & 0xFFFFFF))
print("  byteswap fits the 24-bit measurement? raw %s  dec %s"
      % (bs & 0xFFFFFF == MEAS_RAW, bs_dec & 0xFFFFFF == MEAS_DEC))
print()

# ---- Q1: which 32-bit R fit BOTH measured 24-bit rows? high byte is the only free part ----
# Row B pins R[23:0]=0xB00E17, so only R[31:24] is unknown (256 candidates).
fit = []
for hb in range(256):
    R = (hb << 24) | MEAS_RAW
    if decrypt_data(ARM_WORD, R) & 0xFFFFFF == MEAS_DEC:
        fit.append(R)
print("Q1  R with R[23:0]=0x%06X AND decrypt[23:0]=0x%06X : %d candidate(s)"
      % (MEAS_RAW, MEAS_DEC, len(fit)))
for R in fit:
    tag = "  <-- = byteswap32(golden)" if R == bs else ""
    print("       R = 0x%08X%s" % (R, tag))
print("    => the high byte (the part NOT measured) is %s by the 24-bit data."
      % ("UNIQUELY PINNED" if len(fit) == 1 else "AMBIGUOUS"))
print()

# ---- Q2: could the cab have read a DIFFERENT REAL ROM WORD (wrong-address read)? ----
# Load the whole raw ROM and look for any word that fits the 24 measured bits when
# decrypted at THIS fetch address. If one exists, "wrong word delivered" rivals "byteswap".
a = open(os.path.join(ROM, "ly-00.1f"), "rb").read()
b = open(os.path.join(ROM, "ly-01.2f"), "rb").read()
N = len(a) // 2
raw = [((a[2*i] | (a[2*i+1] << 8)) | ((b[2*i] | (b[2*i+1] << 8)) << 16)) for i in range(N)]

by_raw24  = [j for j in range(N) if raw[j] & 0xFFFFFF == MEAS_RAW]
by_both   = [j for j in range(N)
             if raw[j] & 0xFFFFFF == MEAS_RAW
             and decrypt_data(ARM_WORD, raw[j]) & 0xFFFFFF == MEAS_DEC]
print("Q2  real ROM words with raw[23:0]=0x%06X            : %d" % (MEAS_RAW, len(by_raw24)))
print("    ...of those, also decrypt[23:0]=0x%06X (wrong-addr): %d" % (MEAS_DEC, len(by_both)))
for j in by_both:
    print("       raw_rom[0x%06X]=0x%08X (a real word that fits the measurement)" % (j, raw[j]))
print()

# ---- Q3: is byteswap32(golden) itself a real ROM word anywhere? (the handoff's claim) ----
hits = [j for j in range(N) if raw[j] == bs]
print("Q3  byteswap32(golden)=0x%08X occurs at %d ROM word index(es): %s"
      % (bs, len(hits), [hex(j) for j in hits]))
print()

print("VERDICT")
if len(fit) == 1 and not by_both:
    print("  The 24-bit measurement + decrypt cross-check admit EXACTLY ONE 32-bit value,")
    print("  and it equals byteswap32(golden). No real ROM word fits => not a wrong-address")
    print("  read. The byteswap inference is forced by the data.  (Mechanism still HW/electrical.)")
else:
    print("  The measurement does NOT uniquely force a byteswap:")
    if len(fit) > 1:
        print("   - high byte ambiguous: %d values fit the 24 measured bits." % len(fit))
    if by_both:
        print("   - a REAL ROM word fits too => 'wrong word delivered' (address/arbiter) is live,")
        print("     which is a different bug class than a byte-lane swap.")
