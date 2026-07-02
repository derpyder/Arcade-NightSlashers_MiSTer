#!/bin/bash
# Verilator lint of the assembled video top (jtnslasher_video + tilemap/obj/colmix + jtframe deps).
cd /path/to/nightslashers/jtcores/cores/nslasher/hdl || exit 1
JTF=/path/to/nightslashers/jtcores/modules/jtframe
# EOFNEWLINE/GENUNNAMED are in vendored jtframe files only (not editable here); waive them.
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-EOFNEWLINE -Wno-GENUNNAMED \
  --top-module jtnslasher_vmem \
  -I"$JTF/hdl/video" -I"$JTF/hdl/ram" \
  jtnslasher_vmem.v jtnslasher_video.v jtnslasher_tilemap.v jtnslasher_obj.v jtnslasher_colmix.v \
  "$JTF/hdl/video/jtframe_vtimer.v" "$JTF/hdl/video/jtframe_linebuf.v" \
  "$JTF/hdl/ram/jtframe_rpwp_ram.v" "$JTF/hdl/ram/jtframe_obj_buffer.v" "$JTF/hdl/ram/jtframe_dual_ram.v"
echo "verilator exit=$?"