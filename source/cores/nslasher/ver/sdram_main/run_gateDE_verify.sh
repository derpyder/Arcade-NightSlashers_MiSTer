#!/bin/bash
# GATES D+E: nf24 single-fetch integrity + latency UNDER CONTENTION (BA1 CPU + BA2 4xPF + obj1 + refresh).
set -e
cd "$(dirname "$0")"
IV=/c/iverilog/bin/iverilog.exe
VVP=/c/iverilog/bin/vvp.exe
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
SD=$JT/sdram
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx

# preload/vectors come from the GATE-B chain (same as gate C)
[ -e sdram_bank3.hex ] || python3 gen_objfold_gateC.py

for f in deco56_address.hex deco56_xor.hex deco56_swap.hex \
         deco74_address.hex deco74_xor.hex deco74_swap.hex; do
    [ -e "$f" ] || cp "../gfx/$f" .
done

"$IV" -g2012 -I . -I "$CORE" -I "$GFX" -o tb_obj0_gateDE.vvp \
  tb_obj0_gateDE.v \
  "$CORE/jtnslasher_sdram.v" \
  "$CORE/jtnslasher_gfxdec.v" \
  "$SD/jtframe_rom_1slot.v" "$SD/jtframe_rom_2slots.v" "$SD/jtframe_rom_5slots.v" \
  "$SD/jtframe_romrq.v" "$SD/jtframe_romrq_bcache.v" "$SD/jtframe_romrq_xscache.v" \
  "$SD/jtframe_ramslot_ctrl.v" \
  "$SD/jtframe_sdram64.v" "$SD/jtframe_sdram64_bank.v" "$SD/jtframe_sdram64_init.v" \
  "$SD/jtframe_sdram64_rfsh.v" "$SD/jtframe_sdram64_latch.v" \
  "$JT/ver/mt48lc16m16a2.v"

"$VVP" tb_obj0_gateDE.vvp
