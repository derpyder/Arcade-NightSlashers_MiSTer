#!/bin/bash
# Full-frame video integration sim (M3 task #11): jtframe_vtimer -> jtnslasher_video
# (4x tilemap + 2x obj + colmix) -> RGB, diffed bit-exact vs ref_render.py (cm_rgb.hex).
#   usage: run_video2.sh [frame=1800] [pri=1]
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/gfx || exit 1
FRAME=${1:-1800}; PRI=${2:-1}
JTF=/path/to/nightslashers/jtcores/modules/jtframe
HDL=../../hdl
for f in tb_video2.v $HDL/jtnslasher_video.v $HDL/jtnslasher_tilemap.v $HDL/jtnslasher_obj.v $HDL/jtnslasher_colmix.v; do
  sed -i 's/\r$//' "$f"; done

echo "=== ref_render: golden cm_rgb.hex (frame $FRAME pri $PRI) ==="
python3 ref_render.py "$FRAME" "$PRI" 2>&1 | grep -E "dumped colmix|PRI="
echo "=== reshuffle sprite gfx ==="
python3 reshuffle_spr.py "$FRAME" 2>&1 | grep -E "spr"
echo "=== gen_video config ==="
python3 gen_video.py "$FRAME" "$PRI" || exit 1

echo "=== iverilog ==="
iverilog -g2012 -I. -DSIMULATION -o tb_video2.vvp tb_video2.v \
  $HDL/jtnslasher_video.v $HDL/jtnslasher_tilemap.v $HDL/jtnslasher_obj.v $HDL/jtnslasher_colmix.v \
  "$JTF/hdl/video/jtframe_vtimer.v" "$JTF/hdl/video/jtframe_linebuf.v" \
  "$JTF/hdl/ram/jtframe_rpwp_ram.v" "$JTF/hdl/ram/jtframe_obj_buffer.v" "$JTF/hdl/ram/jtframe_dual_ram.v" \
  2>&1 | head -40
[ -f tb_video2.vvp ] || { echo "COMPILE FAILED"; exit 1; }

echo "=== run ==="
vvp tb_video2.vvp 2>&1 | grep -vE '^(VCD|WARNING.*readmem|INFO|-)' | head
echo "=== compare ==="
python3 cmp_video.py