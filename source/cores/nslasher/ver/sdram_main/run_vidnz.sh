#!/bin/bash
# Run under WSL: validate jtnslasher_vidprobe (probe #1, parked-vs-drawing).
set -e
cd "$(dirname "$0")"
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
iverilog -g2012 -o tb_vidnz.vvp tb_vidnz.v $CORE/jtnslasher_vidprobe.v
vvp tb_vidnz.vvp
