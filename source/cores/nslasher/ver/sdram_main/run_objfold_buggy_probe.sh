#!/bin/bash
set -e
cd "$(dirname "$0")"
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
SD=$JT/sdram
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx
sed -e 's/module tb_objfold_probe;/module tb_objfold_buggy_probe;/' \
    -e 's/jtnslasher_sdram u_dut/jtnslasher_sdram_BUGGY u_dut/' \
    tb_objfold_probe.v > tb_objfold_buggy_probe.v
iverilog -g2012 -I . -I "$CORE" -I "$GFX" -o tb_objfold_buggy_probe.vvp \
  tb_objfold_buggy_probe.v jtnslasher_sdram_BUGGY.v $CORE/jtnslasher_gfxdec.v \
  $SD/jtframe_rom_1slot.v $SD/jtframe_rom_2slots.v $SD/jtframe_romrq.v $SD/jtframe_romrq_bcache.v $SD/jtframe_romrq_xscache.v \
  $SD/jtframe_ramslot_ctrl.v $SD/jtframe_sdram64.v $SD/jtframe_sdram64_bank.v $SD/jtframe_sdram64_init.v $SD/jtframe_sdram64_rfsh.v $SD/jtframe_sdram64_latch.v \
  $JT/ver/mt48lc16m16a2.v
vvp tb_objfold_buggy_probe.vvp
