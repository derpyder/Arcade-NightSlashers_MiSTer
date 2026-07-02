#!/bin/bash
# M3 — compile + run the colour-mixer validation (jtnslasher_colmix) and diff RGB vs golden.
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/gfx || exit 1
for f in tb_colmix.v ../../hdl/jtnslasher_colmix.v ../../hdl/jtnslasher_video.v ../../hdl/jtnslasher_tilemap.v; do sed -i 's/\r$//' "$f"; done
JTF=/path/to/nightslashers/jtcores/modules/jtframe
echo "=== lint jtnslasher_video (structural top) ==="
iverilog -g2012 -t null -DSIMULATION ../../hdl/jtnslasher_video.v ../../hdl/jtnslasher_tilemap.v \
  ../../hdl/jtnslasher_colmix.v "$JTF/hdl/video/jtframe_linebuf.v" "$JTF/hdl/ram/jtframe_rpwp_ram.v" 2>&1 | head -20 && echo "video top OK"
echo "=== iverilog tb_video (full readout path: vtimer -> video -> RGB) ==="
sed -i 's/\r$//' tb_video.v
iverilog -g2012 -DSIMULATION -o tb_video.vvp tb_video.v \
  ../../hdl/jtnslasher_video.v ../../hdl/jtnslasher_tilemap.v ../../hdl/jtnslasher_colmix.v \
  "$JTF/hdl/video/jtframe_vtimer.v" "$JTF/hdl/video/jtframe_linebuf.v" "$JTF/hdl/ram/jtframe_rpwp_ram.v" 2>&1 | head -25
[ -f tb_video.vvp ] || { echo "COMPILE FAILED"; exit 1; }
echo "=== run ==="
vvp tb_video.vvp 2>&1 | grep -vE '^(VCD|WARNING.*\$readmem)' | head
echo "=== compare ==="
python3 cmp_rgb.py
