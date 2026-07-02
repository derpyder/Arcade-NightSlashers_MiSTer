#!/bin/bash
# M3k/task#7b — deco32 video memory subsystem sim: replay f1800 caps through the CPU bus into
# jtnslasher_vmem -> jtnslasher_video -> RGB, diff bit-exact vs ref_render (cm_rgb.hex).
#   usage: run_vmem.sh [frame=1800] [pri=1]
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx
GAME=/path/to/nightslashers/jtcores/cores/nslasher/ver/game
HDL=/path/to/nightslashers/jtcores/cores/nslasher/hdl
JTF=/path/to/nightslashers/jtcores/modules/jtframe
FRAME=${1:-1800}; PRI=${2:-1}
cd "$GFX" || exit 1
for f in "$GAME/tb_vmem.v" $HDL/jtnslasher_vmem.v $HDL/jtnslasher_video.v $HDL/jtnslasher_tilemap.v $HDL/jtnslasher_obj.v $HDL/jtnslasher_colmix.v; do
  sed -i 's/\r$//' "$f"; done

echo "=== ref_render golden + reshuffle + gen_video (frame $FRAME pri $PRI) ==="
python3 ref_render.py "$FRAME" "$PRI" 2>&1 | grep -E "dumped colmix|PRI="
python3 reshuffle_spr.py "$FRAME" 2>&1 | grep -E "spr"
python3 gen_video.py "$FRAME" "$PRI" || exit 1

echo "=== iverilog ==="
iverilog -g2012 -I"$GFX" -DSIMULATION -o "$GAME/tb_vmem.vvp" "$GAME/tb_vmem.v" \
  $HDL/jtnslasher_vmem.v $HDL/jtnslasher_video.v $HDL/jtnslasher_tilemap.v $HDL/jtnslasher_obj.v $HDL/jtnslasher_colmix.v \
  "$JTF/hdl/video/jtframe_vtimer.v" "$JTF/hdl/video/jtframe_linebuf.v" \
  "$JTF/hdl/ram/jtframe_rpwp_ram.v" "$JTF/hdl/ram/jtframe_obj_buffer.v" "$JTF/hdl/ram/jtframe_dual_ram.v" \
  2>&1 | head -40
[ -f "$GAME/tb_vmem.vvp" ] || { echo "COMPILE FAILED"; exit 1; }

echo "=== run ==="
vvp "$GAME/tb_vmem.vvp" 2>&1 | grep -vE '^(VCD|WARNING.*readmem|INFO|-)' | head
echo "=== compare ==="
python3 cmp_video.py frame_vmem.hex