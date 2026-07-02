#!/bin/bash
# M3k/task#7c-3b-int — Arch B integration sim: f1800 cap replay -> jtnslasher_vmem -> jtnslasher_sdram
# (4x jtnslasher_gfxdec at-fetch decrypt wrappers + obj0 40-bit split) -> 16-bit encrypted reorder(raw)
# gfx1/2 + render-format gfx3/4, per-bank contention -> RGB, diff bit-exact vs ref_render.
#   usage: run_intg.sh [frame=1800] [pri=1]
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx
GAME=/path/to/nightslashers/jtcores/cores/nslasher/ver/game
HDL=/path/to/nightslashers/jtcores/cores/nslasher/hdl
JTF=/path/to/nightslashers/jtcores/modules/jtframe
FRAME=${1:-1800}; PRI=${2:-1}
LOWLAT=${LOWLAT-1}   # default = render-correctness gate (bit-exact). `LOWLAT= run_intg.sh` = heavy
                     # bandwidth probe (Arch B 2-reads/word oversubscribes BA2 -> ~4% tiles drop to X).
cd "$GFX" || exit 1
for f in "$GAME/tb_intg.v" $HDL/jtnslasher_sdram.v $HDL/jtnslasher_gfxdec.v $HDL/jtnslasher_vmem.v $HDL/jtnslasher_video.v $HDL/jtnslasher_tilemap.v $HDL/jtnslasher_obj.v $HDL/jtnslasher_colmix.v; do
  sed -i 's/\r$//' "$f"; done

echo "=== golden + reshuffle + gen_video + down_pass emit (frame $FRAME pri $PRI) ==="
python3 ref_render.py "$FRAME" "$PRI" 2>&1 | grep -E "dumped colmix|PRI="
python3 reshuffle_spr.py "$FRAME" 2>&1 | grep -E "spr"
python3 gen_video.py "$FRAME" "$PRI" || exit 1
ROMDIR=/path/to/nightslashers/roms python3 down_pass.py emit | tail -1

echo "=== iverilog ==="
iverilog -g2012 -I"$GFX" -DSIMULATION ${LOWLAT:+-DLOWLAT} -o "$GFX/tb_intg.vvp" "$GAME/tb_intg.v" \
  $HDL/jtnslasher_sdram.v $HDL/jtnslasher_gfxdec.v $HDL/jtnslasher_vmem.v $HDL/jtnslasher_video.v $HDL/jtnslasher_tilemap.v $HDL/jtnslasher_obj.v $HDL/jtnslasher_colmix.v \
  "$JTF/hdl/video/jtframe_vtimer.v" "$JTF/hdl/video/jtframe_linebuf.v" \
  "$JTF/hdl/ram/jtframe_rpwp_ram.v" "$JTF/hdl/ram/jtframe_obj_buffer.v" "$JTF/hdl/ram/jtframe_dual_ram.v" \
  2>&1 | head -40
[ -f "$GFX/tb_intg.vvp" ] || { echo "COMPILE FAILED"; exit 1; }

echo "=== run (from ver/gfx so the wrapper table .hex resolve) ==="
vvp "$GFX/tb_intg.vvp" 2>&1 | grep -vE '^(VCD|WARNING.*readmem|INFO|-)' | head
echo "=== compare ==="
python3 cmp_video.py frame_intg.hex
