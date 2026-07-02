#!/bin/bash
# M3c — compile + run the jtnslasher_tilemap validation tb, then diff vs the golden frame.
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/gfx || exit 1
JTF=/path/to/nightslashers/jtcores/modules/jtframe
# strip CRLF from the RTL we compile (Windows-authored)
for f in tb_tilemap.v ../../hdl/jtnslasher_tilemap.v; do sed -i 's/\r$//' "$f"; done
echo "=== iverilog ==="
iverilog -g2012 -DSIMULATION -o tb_tilemap.vvp \
  tb_tilemap.v ../../hdl/jtnslasher_tilemap.v \
  "$JTF/hdl/video/jtframe_linebuf.v" "$JTF/hdl/ram/jtframe_rpwp_ram.v" 2>&1 | head -40
[ -f tb_tilemap.vvp ] || { echo "COMPILE FAILED"; exit 1; }
echo "=== run ==="
vvp tb_tilemap.vvp 2>&1 | grep -vE '^(VCD|WARNING.*\$readmem)' | head -20
echo "=== compare ==="
python3 cmp_frame.py
