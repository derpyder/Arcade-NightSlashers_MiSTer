#!/bin/bash
# Build + run the latency-injecting obj tb at several ROM latencies, compare each to golden.
# Assumes golden_obj.hex + obj_cfg.vh already built for the target frame/layer.
set -e
cd "$(dirname "$0")"
ROOT=/path/to/nightslashers/jtcores
CORE=$ROOT/cores/nslasher/hdl
JTF=$ROOT/modules/jtframe/hdl
for LAT in 2 4 8 16 32; do
  iverilog -g2012 -I . -I "$CORE" -DLAT=$LAT -DBUDGET=4000 -o tb_obj_lat.vvp \
    tb_obj_lat.v "$CORE/jtnslasher_obj.v" "$JTF/ram/jtframe_obj_buffer.v" "$JTF/ram/jtframe_dual_ram.v"
  vvp tb_obj_lat.vvp >/dev/null
  printf "LAT=%-3d -> " "$LAT"; python3 cmp_obj.py | head -1
done
