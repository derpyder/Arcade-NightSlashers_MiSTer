#!/bin/bash
# FAITHFUL seam sim: real obj0 FSM (jtnslasher_sdram) + real DW32-DOUBLE OKLATCH=1 cache/SDRAM,
# driven by a faithful jtnslasher_obj-cadence engine at REAL addresses, back-to-back.
# Run under WSL iverilog v12.
set -e
cd "$(dirname "$0")"
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
SD=$JT/sdram
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx

# regenerate REAL-address preload + test vectors
python3 gen_objfold_real.py

# deco tables for the (unused) gfxdec instances
for f in deco56_address.hex deco56_xor.hex deco56_swap.hex \
         deco74_address.hex deco74_xor.hex deco74_swap.hex; do
    [ -e "$f" ] || cp "$GFX/$f" .
done

# the mt48lc16m16a2 model $readmemh's "sdram_bank3.hex" by default name in tb_objfold_combined;
# our tb uses sdram_bank3_real.hex via the model's plusarg/define? No -- the model loads a fixed name.
# Provide it under the name the model expects by symlink/copy. Inspect: the model reads from a +arg or
# a hard-coded file. We pass it through a defparam-free copy step:
cp -f sdram_bank3_real.hex sdram_bank3.hex

iverilog -g2012 -I . -I "$CORE" -I "$GFX" -o tb_objfold_real.vvp \
  tb_objfold_real.v \
  $CORE/jtnslasher_sdram.v \
  $CORE/jtnslasher_gfxdec.v \
  $SD/jtframe_rom_1slot.v $SD/jtframe_rom_2slots.v \
  $SD/jtframe_romrq.v $SD/jtframe_romrq_bcache.v $SD/jtframe_romrq_xscache.v \
  $SD/jtframe_ramslot_ctrl.v \
  $SD/jtframe_sdram64.v $SD/jtframe_sdram64_bank.v $SD/jtframe_sdram64_init.v \
  $SD/jtframe_sdram64_rfsh.v $SD/jtframe_sdram64_latch.v \
  $JT/ver/mt48lc16m16a2.v

vvp tb_objfold_real.vvp
