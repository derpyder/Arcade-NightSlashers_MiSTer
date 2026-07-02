#!/bin/bash
# FIX B gate: joint-8bpp bio replay through jtnslasher_colmix vs the MAME-snapshot-exact golden.
# bio_render.py must be pixel-exact vs MAME first (it asserts/reports); then the RTL must match it.
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/gfx || exit 1
FRAME=${1:-3000}
for f in tb_colmix_bio.v ../../hdl/jtnslasher_colmix.v; do sed -i 's/\r$//' "$f"; done
echo "=== bio_render: model vs MAME snapshot + stream dump (frame $FRAME) ==="
python3 bio_render.py "$FRAME" 2>&1 | grep -E "pixels differ|dumped"
echo "=== iverilog ==="
JTF=/path/to/nightslashers/jtcores/modules/jtframe
iverilog -g2012 -I. -o tb_colmix_bio.vvp tb_colmix_bio.v ../../hdl/jtnslasher_colmix.v "$JTF/hdl/ram/jtframe_dual_ram.v" 2>&1 | head -20
[ -f tb_colmix_bio.vvp ] || { echo "COMPILE FAILED"; exit 1; }
echo "=== run ==="
vvp tb_colmix_bio.vvp 2>&1 | grep -vE '^(VCD|WARNING.*readmem)' | head -10
