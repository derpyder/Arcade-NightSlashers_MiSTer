#!/bin/bash
# Build + run the deco_ace buffered-palette fade proof: for each cfg,
#   1) UNFIXED (original backup, no paldma)  -> must REPRODUCE the drift
#   2) FIXED   (patched colmix, with paldma) -> faded frozen to fade(B0), DMA advances it
set -e
cd "$(dirname "$0")"
export PATH="/c/iverilog/bin:$PATH"
ROOT=/d/deck/fpga/nightslashers/jtcores
CORE=$ROOT/cores/nslasher/hdl
JTF=$ROOT/modules/jtframe/hdl
ORIG=$CORE/jtnslasher_colmix.v.orig-buffered-fix-bak
FIXED=$CORE/jtnslasher_colmix.v
RAM=$JTF/ram/jtframe_dual_ram.v

for CFG in dialog bio; do
  echo "################## cfg=$CFG ##################"
  python3 gen_bufferfade_test.py "$CFG"
  echo "------- UNFIXED (repro) -------"
  iverilog -g2012 -DUNFIXED -I . -I "$CORE" -o tb_bf_unfixed.vvp \
    tb_colmix_bufferfade.v "$ORIG" "$RAM"
  vvp tb_bf_unfixed.vvp
  echo "------- FIXED -------"
  iverilog -g2012 -DHAVE_PALDMA -I . -I "$CORE" -o tb_bf_fixed.vvp \
    tb_colmix_bufferfade.v "$FIXED" "$RAM"
  vvp tb_bf_fixed.vvp
  echo
done
