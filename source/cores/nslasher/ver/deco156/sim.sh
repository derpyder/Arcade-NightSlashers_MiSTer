#!/bin/bash
# Night Slashers — deco156 ARM-decrypt unit test (M2b).
# Usage: cd $JTROOT && source setprj.sh && cd cores/nslasher/ver/deco156 && ./sim.sh
set -e
python3 gold.py
iverilog -g2012 -o tb.vvp tb_deco156.v ../../hdl/jtnslasher_deco156.v
vvp tb.vvp
