#!/bin/bash
# Build + run jtnslasher_obj testbench (tb_obj.v) for a given frame+layer, then compare to MAME golden.
#   usage: run_obj.sh <frame> <spr0|spr1>
set -e
cd "$(dirname "$0")"
FRAME=${1:-1800}
LAYER=${2:-spr0}
ROOT=/path/to/nightslashers/jtcores
CORE=$ROOT/cores/nslasher/hdl
JTF=$ROOT/modules/jtframe/hdl

# 1. reshuffle gfx for this frame's used tiles, build golden + obj_cfg.vh
python3 reshuffle_spr.py "$FRAME"
python3 gen_obj_golden.py "$FRAME" "$LAYER"
echo "--- obj_cfg.vh ---"; cat obj_cfg.vh

# 2. compile + run the obj engine tb
iverilog -g2012 -I . -I "$CORE" -o tb_obj.vvp \
  tb_obj.v "$CORE/jtnslasher_obj.v" "$JTF/ram/jtframe_obj_buffer.v" "$JTF/ram/jtframe_dual_ram.v"
vvp tb_obj.vvp

# 3. compare
python3 cmp_obj.py
