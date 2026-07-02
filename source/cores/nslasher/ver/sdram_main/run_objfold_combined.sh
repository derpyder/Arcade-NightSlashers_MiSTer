#!/bin/bash
# Combined seam sim: real obj0 FSM (jtnslasher_sdram) + real DW32-DOUBLE OKLATCH=1 cache/SDRAM.
# Run under WSL iverilog v12.
set -e
cd "$(dirname "$0")"
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
SD=$JT/sdram
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx

# regenerate preload + test vectors
python3 gen_objfold_combined.py

# jtnslasher_gfxdec (instantiated but unused in the DUT) $readmemh's the deco tables at init;
# make them resolvable from this cwd so iverilog doesn't choke on missing files.
for f in deco56_address.hex deco56_xor.hex deco56_swap.hex \
         deco74_address.hex deco74_xor.hex deco74_swap.hex; do
    [ -e "$f" ] || cp "$GFX/$f" .
done

iverilog -g2012 -I . -I "$CORE" -I "$GFX" -o tb_objfold_combined.vvp \
  tb_objfold_combined.v \
  $CORE/jtnslasher_sdram.v \
  $CORE/jtnslasher_gfxdec.v \
  $SD/jtframe_rom_1slot.v $SD/jtframe_rom_2slots.v \
  $SD/jtframe_romrq.v $SD/jtframe_romrq_bcache.v $SD/jtframe_romrq_xscache.v \
  $SD/jtframe_ramslot_ctrl.v \
  $SD/jtframe_sdram64.v $SD/jtframe_sdram64_bank.v $SD/jtframe_sdram64_init.v \
  $SD/jtframe_sdram64_rfsh.v $SD/jtframe_sdram64_latch.v \
  $JT/ver/mt48lc16m16a2.v

vvp tb_objfold_combined.vvp
