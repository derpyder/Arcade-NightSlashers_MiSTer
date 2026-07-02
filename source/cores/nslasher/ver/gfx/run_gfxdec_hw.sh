#!/bin/bash
# Validate the gfx byteswap16 HW fix: feed the gfxdec a byteswapped (HW-modelled) SDRAM and confirm the
# FIXED gfxdec recovers the render-format golden. (1) +HWSWAP -> must be BIT-EXACT. (2) no HWSWAP (correct
# order) -> must FAIL, proving the byteswap16 is actively applied by the fix.
set -e
cd "$(dirname "$0")"
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
DEFS='-DSDRW=528384 -DREORDFILE="r1_gfx1.hex" -DGOLDFILE="gfx1_chars8.hex"
      -DADDRF="deco56_address.hex" -DXORF="deco56_xor.hex" -DSWAPF="deco56_swap.hex"
      -DCHARS8=1 -DNTEST=256 -DLABEL="PF1_chars8" -DLAT=2'

echo "=== (1) fixed gfxdec + HWSWAP (models HW byteswapped SDRAM) -> expect BIT-EXACT ==="
iverilog -g2012 -I. $DEFS -DHWSWAP -o tb_hw.vvp tb_gfxdec.v $CORE/jtnslasher_gfxdec.v
vvp tb_hw.vvp | grep -E "gfxdec|mismatch"

echo "=== (2) fixed gfxdec, NO HWSWAP (correct-order data) -> expect FAIL (fix is active) ==="
iverilog -g2012 -I. $DEFS -o tb_nohw.vvp tb_gfxdec.v $CORE/jtnslasher_gfxdec.v
vvp tb_nohw.vvp | grep -E "gfxdec|mismatch"
