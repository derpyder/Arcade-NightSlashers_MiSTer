#!/bin/bash
# Sweep the per-line cycle BUDGET at fixed ROM latency, to find where the engine runs out of
# time on the busiest line (HW "timing under load"). Reports match% per budget.
cd "$(dirname "$0")"
ROOT=/path/to/nightslashers/jtcores
CORE=$ROOT/cores/nslasher/hdl
JTF=$ROOT/modules/jtframe/hdl
LAT=${1:-16}
for B in 250 300 400 600 1000 2000; do
  iverilog -g2012 -I . -I "$CORE" -DLAT="$LAT" -DBUDGET="$B" -o tb_obj_lat.vvp \
    tb_obj_lat.v "$CORE/jtnslasher_obj.v" "$JTF/ram/jtframe_obj_buffer.v" "$JTF/ram/jtframe_dual_ram.v" 2>/dev/null
  vvp tb_obj_lat.vvp >/dev/null 2>&1
  res=$(python3 cmp_obj.py | head -1)
  echo "BUDGET=$B LAT=$LAT -> $res"
done
