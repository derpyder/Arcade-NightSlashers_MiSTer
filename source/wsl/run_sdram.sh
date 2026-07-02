#!/bin/bash
# M3k/task#7c-2 — gfx SDRAM serving sim: f1800 cap replay -> jtnslasher_vmem -> jtnslasher_sdram
# (fetch adapter: PF3/PF4 share gfx2, obj0 5bpp 40-bit split obj0lo+obj0hi) -> behavioral SDRAM with
# per-bank arbitration + variable latency + obj0lo/obj0hi skew -> RGB, diff bit-exact vs ref_render.
#   usage: run_sdram.sh [frame=1800] [pri=1]
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx
GAME=/path/to/nightslashers/jtcores/cores/nslasher/ver/game
HDL=/path/to/nightslashers/jtcores/cores/nslasher/hdl
JTF=/path/to/nightslashers/jtcores/modules/jtframe
FRAME=${1:-1800}; PRI=${2:-1}
cd "$GFX" || exit 1
for f in "$GAME/tb_sdram.v" $HDL/jtnslasher_sdram.v $HDL/jtnslasher_vmem.v $HDL/jtnslasher_video.v $HDL/jtnslasher_tilemap.v $HDL/jtnslasher_obj.v $HDL/jtnslasher_colmix.v; do
  sed -i 's/\r$//' "$f"; done

echo "=== ref_render golden + reshuffle + gen_video (frame $FRAME pri $PRI) ==="
python3 ref_render.py "$FRAME" "$PRI" 2>&1 | grep -E "dumped colmix|PRI="
python3 reshuffle_spr.py "$FRAME" 2>&1 | grep -E "spr"
python3 gen_video.py "$FRAME" "$PRI" || exit 1

echo "=== iverilog ==="
iverilog -g2012 -I"$GFX" -DSIMULATION -o "$GAME/tb_sdram.vvp" "$GAME/tb_sdram.v" \
  $HDL/jtnslasher_sdram.v $HDL/jtnslasher_vmem.v $HDL/jtnslasher_video.v $HDL/jtnslasher_tilemap.v $HDL/jtnslasher_obj.v $HDL/jtnslasher_colmix.v \
  "$JTF/hdl/video/jtframe_vtimer.v" "$JTF/hdl/video/jtframe_linebuf.v" \
  "$JTF/hdl/ram/jtframe_rpwp_ram.v" "$JTF/hdl/ram/jtframe_obj_buffer.v" "$JTF/hdl/ram/jtframe_dual_ram.v" \
  2>&1 | head -40
[ -f "$GAME/tb_sdram.vvp" ] || { echo "COMPILE FAILED"; exit 1; }

echo "=== run ==="
vvp "$GAME/tb_sdram.vvp" 2>&1 | grep -vE '^(VCD|WARNING.*readmem|INFO|-)' | head
echo "=== compare ==="
python3 cmp_video.py frame_sdram.hex
