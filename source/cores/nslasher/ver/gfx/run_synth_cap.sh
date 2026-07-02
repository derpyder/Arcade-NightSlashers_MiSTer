#!/bin/bash
# Build a synthetic >40-tiles-on-one-line frame and run the obj engine vs MAME golden, to isolate
# the line_cnt>=40 per-line cap.  usage: run_synth_cap.sh <ntiles>
set -e
cd "$(dirname "$0")"
ROOT=/path/to/nightslashers/jtcores
CORE=$ROOT/cores/nslasher/hdl
JTF=$ROOT/modules/jtframe/hdl
N=${1:-50}
python3 gen_synth_cap.py "$N"
python3 reshuffle_spr.py 9999 | tail -1
python3 gen_obj_golden.py 9999 spr0 | tail -1
iverilog -g2012 -I . -I "$CORE" -o tb_obj.vvp \
  tb_obj.v "$CORE/jtnslasher_obj.v" "$JTF/ram/jtframe_obj_buffer.v" "$JTF/ram/jtframe_dual_ram.v"
vvp tb_obj.vvp >/dev/null
python3 cmp_obj.py | head -3
