#!/usr/bin/env python3
# Offline model of the FULL hardware main-ROM path for Night Slashers:
#   download blob byte-stream  ->  jtframe_dwnld write into 16-bit SDRAM
#   ->  jtframe_rom_4slots / romrq_bcache 32-bit DOUBLE read assembly
# Goal: read back the RAW (encrypted) 32-bit word at deco156 scrambled SDRAM word
# 0x023608 (ARM byte 0x095050) the way HW does, and compare to expected 0x170EB025.
#
# Run:  cd ver/arm ; python model_sdram_path.py
import os, sys

D   = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROMDIR", os.path.join(D, "..", "..", "..", "..", "..", "roms"))

# ---------------- 1. assemble the main-ROM blob (identity, BA1 @ 0) -----------------
# make_rom.py: word[i] = (le16(2f,i) << 16) | le16(1f,i)  -- 32-bit little-endian image.
# The download blob for BA1 is exactly this image, byte-for-byte (mra_assemble confirms
# word32(i*4)==raw[i], with word32 = blob[off] | blob[off+1]<<8 | blob[off+2]<<16 | blob[off+3]<<24).
a = open(os.path.join(ROM, "ly-00.1f"), "rb").read()
b = open(os.path.join(ROM, "ly-01.2f"), "rb").read()
assert len(a) == 0x80000 and len(b) == 0x80000, (len(a), len(b))
nwords = len(a) // 2  # 0x40000

raw_rom = []                 # raw_rom[i] = encrypted 32-bit ARM word i
blob    = bytearray()        # the byte stream the loader delivers (BA1 region)
for i in range(nwords):
    lo = a[2*i] | (a[2*i+1] << 8)
    hi = b[2*i] | (b[2*i+1] << 8)
    w  = ((hi << 16) | lo) & 0xffffffff
    raw_rom.append(w)
    # little-endian bytes into the blob (identity layout)
    blob += bytes([w & 0xff, (w >> 8) & 0xff, (w >> 16) & 0xff, (w >> 24) & 0xff])

print("blob (BA1 main) = 0x%X bytes, raw_rom = %d words" % (len(blob), len(raw_rom)))

# ---------------- 2. deco156 address scramble (to get dec_saddr) --------------------
ADDRX = [0xce4a,0x4db2,0xef60,0x5737,0x13dc,0x4bd9,0xa209,0xd996,
         0xa700,0xeca0,0x7529,0x3100,0x33b4,0x6161,0x1eef,0xf5a5]
def dec_saddr(arm_word):
    lo = 0x92c6
    for i in range(16):
        if (arm_word >> i) & 1:
            lo ^= ADDRX[i]
    return ((arm_word >> 16) & 0x3) << 16 | (lo & 0xffff)   # keep a[17:16]

ARM_BYTE = 0x095050
arm_word = ARM_BYTE >> 2                      # a = wb_adr[19:2]
saddr    = dec_saddr(arm_word)
print("ARM byte 0x%06X -> arm_word 0x%05X -> dec_saddr (SDRAM 32-bit word) 0x%06X"
      % (ARM_BYTE, arm_word, saddr))
EXPECT_RAW = 0x170EB025
print("expected raw_rom[0x%06X] (golden) = 0x%08X" % (saddr, raw_rom[saddr] if saddr < len(raw_rom) else -1))

# ---------------- 3. model the download WRITE into 16-bit SDRAM ---------------------
# jtframe_dwnld.v (SWAB=1, BA1 identity -> eff_addr == byte offset within BA1):
#   prog_addr <= eff_addr[SDRAMW-2:0]   (16-bit-WORD address; bit0 dropped)
#   prog_data  = {2{data_out}}          (byte duplicated to both lanes)
#   prog_mask <= (eff_addr[0]^SWAB[0]) ? 2'b10 : 2'b01   (active-low mask; chooses lane)
# In jtframe_sdram the active-low mask gates which 8-bit lane of the 16-bit word is written.
# mask 2'b01 (active-low) -> low byte [7:0] written ; mask 2'b10 -> high byte [15:8] written.
SWAB = 1
sdram16 = {}   # 16-bit-word address -> 16-bit value
for byte_off, val in enumerate(blob):
    eff_addr  = byte_off                        # BA1 identity (offset subtracted = 0)
    word_addr = eff_addr >> 1                   # prog_addr = eff_addr[..:1]
    mask      = 0b10 if ((eff_addr & 1) ^ (SWAB & 1)) else 0b01   # active-low
    cur = sdram16.get(word_addr, 0)
    # active-low: bit set in mask means that lane is NOT written; bit clear => write it.
    # mask 2'b01 => bit0=1 (high?) -- careful: jtframe convention: prog_mask is the
    # write *mask*, active low, where bit0 controls the LOW byte, bit1 the HIGH byte.
    # 2'b01 means low-byte-lane masked? Decode both interpretations and test.
    sdram16[word_addr] = (cur, mask, val, eff_addr & 1)  # stash, resolve after we pin convention

# We must pin the jtframe prog_mask convention. In jtframe_sdram64_bank the byte enables
# are derived as ~prog_mask, with bit0 = low byte, bit1 = high byte. So:
#   prog_mask=2'b01 -> ~ = 2'b10 -> write HIGH byte
#   prog_mask=2'b10 -> ~ = 2'b01 -> write LOW byte
# With SWAB=1: even byte (eff[0]=0) -> mask 2'b10 -> writes LOW byte
#              odd  byte (eff[0]=1) -> mask 2'b01 -> writes HIGH byte
# i.e. SWAB=1 keeps the natural little-endian byte order inside the 16-bit word.
sdram = {}
for byte_off, val in enumerate(blob):
    eff_addr  = byte_off
    word_addr = eff_addr >> 1
    mask      = 0b10 if ((eff_addr & 1) ^ (SWAB & 1)) else 0b01
    cur = sdram.get(word_addr, 0)
    if mask == 0b10:        # ~mask=01 -> low byte
        cur = (cur & 0xff00) | val
    else:                   # mask==01 -> ~mask=10 -> high byte
        cur = (cur & 0x00ff) | (val << 8)
    sdram[word_addr] = cur

# ---------------- 4. model the READ (32-bit DOUBLE slot) ---------------------------
# romrq_bcache (DW=32, DOUBLE=1): slot0_addr = {main_addr, 1'b0} (19-bit),
#   addr_req = {addr[18:1],1'b0} = {main_addr,1'b0}; sdram_addr = addr_req (no >>, DW!=8).
#   Reads two 16-bit SDRAM words: at addr_req and addr_req^2, assembling
#   cached_data0[15:0] = first 16-bit (low half), [31:16] = second (high half).
# main_addr fed to slot = main_rom_a[17:0] = dec_saddr (since rom_addr={4'd0,dec_saddr}).
main_addr = saddr & 0x3ffff
addr_req  = (main_addr << 1) & ~1     # {main_addr,1'b0}
def read32(addr_req):
    # SDRAM burst=4x16; DOUBLE consumes two CONSECUTIVE 16-bit beats: N (low), N+1 (high)
    w_lo = sdram.get(addr_req,     0)  # SDRAM 16-bit word at addr_req
    w_hi = sdram.get(addr_req + 1, 0)  # next consecutive 16-bit word
    return (w_hi << 16) | w_lo, addr_req, addr_req + 1

got, h0, h1 = read32(addr_req)
print()
print("addr_req (sdram base 16-bit-word) = 0x%06X = main_addr<<1" % addr_req)
print("READ-side 16-bit SDRAM word halves: low @0x%06X  high @0x%06X" % (h0, h1))
print("  SDRAM[0x%06X] = 0x%04X   SDRAM[0x%06X] = 0x%04X" % (h0, sdram.get(h0,0), h1, sdram.get(h1,0)))
print("assembled raw 32-bit word = 0x%08X" % got)
print("expected                  = 0x%08X" % EXPECT_RAW)
print("MATCH" if got == EXPECT_RAW else ">>> MISMATCH <<<")

# ---------------- 5. cross-check: does this addressing match for ALL words? --------
# If the model is the real HW path, read32 for EVERY word must equal raw_rom.
bad = 0; first = []
for i in range(nwords):
    ar = (i << 1) & ~1
    g, _, _ = read32(ar)
    if g != raw_rom[i]:
        bad += 1
        if len(first) < 5: first.append((i, g, raw_rom[i]))
print()
print("full-image read-back self-check: %d / %d words mismatch" % (bad, nwords))
for i, g, r in first:
    print("   word 0x%06X: got 0x%08X  ref 0x%08X" % (i, g, r))
