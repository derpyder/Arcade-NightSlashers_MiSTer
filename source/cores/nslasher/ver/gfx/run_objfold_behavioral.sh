#!/bin/bash
# Regression: behavioral-SDRAM render-correctness sim (tb_objfold.v) against the obj0 FSM.
# Confirms the fresh-ok hardening in jtnslasher_sdram.v did not regress the proven bit-exact path.
set -e
cd "$(dirname "$0")"
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
python3 gen_objfold.py >/dev/null
iverilog -g2012 -I . -I "$CORE" -o tb_objfold_regress.vvp \
  tb_objfold.v "$CORE/jtnslasher_sdram.v" "$CORE/jtnslasher_gfxdec.v"
vvp tb_objfold_regress.vvp
