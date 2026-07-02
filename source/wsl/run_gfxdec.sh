#!/bin/bash
# 7c-3b — at-fetch gfx decrypt+reshuffle wrapper unit sim. Runs all 3 tilemap layers; each must be
# BIT-EXACT vs the render-format golden (proves the RTL matches the Python-proven down_pass.py spec).
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx
HDL=/path/to/nightslashers/jtcores/cores/nslasher/hdl
cd "$GFX" || exit 1
sed -i 's/\r$//' "$GFX/tb_gfxdec.v" "$HDL/jtnslasher_gfxdec.v"

echo "=== emit decrypt tables + reorder(raw) SDRAM images ==="
ROMDIR=/path/to/nightslashers/roms python3 down_pass.py emit | tail -1

run() {  # label chars8 gold reord addr xor swap
  echo "=== $1 ==="
  iverilog -g2012 -I"$GFX" -o /tmp/tb_gfxdec.vvp \
    -D LABEL="\"$1\"" -D CHARS8=$2 -D GOLDFILE="\"$3\"" -D REORDFILE="\"$4\"" \
    -D ADDRF="\"$5\"" -D XORF="\"$6\"" -D SWAPF="\"$7\"" \
    -D NTEST=16384 -D SDRW=1048576 -D LAT=3 \
    "$GFX/tb_gfxdec.v" "$HDL/jtnslasher_gfxdec.v" 2>&1 | head -20
  [ -f /tmp/tb_gfxdec.vvp ] || { echo "COMPILE FAILED"; return 1; }
  vvp /tmp/tb_gfxdec.vvp 2>&1 | grep -vE '^(VCD|WARNING.*readmem|-)' | grep -E "gfxdec|mismatch"
}

run "PF2_gfx1_tiles16" 0 gfx1_tiles16.hex r1_gfx1.hex deco56_address.hex deco56_xor.hex deco56_swap.hex
run "PF1_gfx1_chars8"  1 gfx1_chars8.hex  r1_gfx1.hex deco56_address.hex deco56_xor.hex deco56_swap.hex
run "PF34_gfx2_tiles16" 0 gfx2_tiles16.hex r2_gfx2.hex deco74_address.hex deco74_xor.hex deco74_swap.hex
echo DONE
