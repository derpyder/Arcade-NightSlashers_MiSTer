#!/bin/bash
# REAL obj engine + REAL fold FSM + REAL sdram64 + refresh contention.
set -e
cd "$(dirname "$0")"
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
SD=$JT/sdram
RAM=$JT/ram
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx
python3 gen_objfold_real.py >/dev/null
cp -f sdram_bank3_real.hex sdram_bank3.hex
for f in deco56_address.hex deco56_xor.hex deco56_swap.hex deco74_address.hex deco74_xor.hex deco74_swap.hex; do
    [ -e "$f" ] || cp "$GFX/$f" .
done
iverilog -g2012 -DSIMULATION -DJTFRAME_SIM_SDRAM_NONSTOP -DJTFRAME_SIM_ROMRQ_NOCHECK -I . -I "$CORE" -I "$GFX" -o tb_obj_engine_cont.vvp \
  tb_obj_engine_cont.v \
  $CORE/jtnslasher_sdram.v $CORE/jtnslasher_gfxdec.v $CORE/jtnslasher_obj.v \
  $RAM/jtframe_obj_buffer.v $RAM/jtframe_dual_ram.v \
  $SD/jtframe_rom_1slot.v $SD/jtframe_rom_2slots.v $SD/jtframe_romrq.v $SD/jtframe_romrq_bcache.v $SD/jtframe_romrq_xscache.v \
  $SD/jtframe_ramslot_ctrl.v $SD/jtframe_sdram64.v $SD/jtframe_sdram64_bank.v $SD/jtframe_sdram64_init.v \
  $SD/jtframe_sdram64_rfsh.v $SD/jtframe_sdram64_latch.v $JT/ver/mt48lc16m16a2.v
vvp tb_obj_engine_cont.vvp
