#!/bin/bash
# M4 fix round 3: add framework video/ram helpers that `jtframe files` missed (vtimer, obj_buffer, ...).
# Only adds files not already in files.qip (avoid duplicate-entity errors).
WINB=/path/to/nightslashers/jtcores
QIP=$WINB/cores/nslasher/mister/files.qip
WINP='/path/to/nightslashers/jtcores'
# candidate set = the framework files run_game.sh listed explicitly beyond the auto set
cands="video/jtframe_vtimer.v video/jtframe_linebuf.v ram/jtframe_dual_ram.v ram/jtframe_obj_buffer.v ram/jtframe_rpwp_ram.v ram/jtframe_ram.v ram/jtframe_dual_nvram.v"
for rel in $cands; do
  base=$(basename "$rel")
  if grep -q "/$base\b" "$QIP"; then
    echo "present : $base"
  else
    echo "set_global_assignment -name VERILOG_FILE $WINP/modules/jtframe/hdl/$rel" >> "$QIP"
    echo "ADDED   : $base"
  fi
done
echo "files.qip now $(wc -l < "$QIP") lines"
echo DONE_FIX3
