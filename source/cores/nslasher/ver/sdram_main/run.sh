#!/bin/bash
# Run under WSL: iverilog faithful read-path harness.
set -e
cd "$(dirname "$0")"
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
SD=$JT/sdram
iverilog -g2012 -o tb_mainrom.vvp \
  tb_mainrom.v \
  $SD/jtframe_rom_4slots.v \
  $SD/jtframe_romrq.v \
  $SD/jtframe_romrq_bcache.v \
  $SD/jtframe_romrq_xscache.v \
  $SD/jtframe_ramslot_ctrl.v \
  $SD/jtframe_sdram64.v \
  $SD/jtframe_sdram64_bank.v \
  $SD/jtframe_sdram64_init.v \
  $SD/jtframe_sdram64_rfsh.v \
  $SD/jtframe_sdram64_latch.v \
  $JT/ver/mt48lc16m16a2.v
vvp tb_mainrom.vvp
