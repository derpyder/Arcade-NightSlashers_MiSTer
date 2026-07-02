#!/bin/bash
# GATE C: nf24 single-fetch correctness + single-burst property.
# real nf24 jtnslasher_sdram.v + real jtframe_rom_1slot (DW32 DOUBLE) + sdram64 (BA3_LEN=64) + mt48lc16m16a2,
# fed the GATE-B-chain image (real .mra -> big-endian mra2rom -> dwnld remap). NOT self-consistent.
set -e
cd "$(dirname "$0")"
IV=/c/iverilog/bin/iverilog.exe
VVP=/c/iverilog/bin/vvp.exe
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
SD=$JT/sdram
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx

# regenerate the GATE-B-chain preload + vectors + golden
python3 gen_objfold_gateC.py

# deco tables for the (unused) gfxdec instances
for f in deco56_address.hex deco56_xor.hex deco56_swap.hex \
         deco74_address.hex deco74_xor.hex deco74_swap.hex; do
    [ -e "$f" ] || cp "../gfx/$f" .
done

"$IV" -g2012 -I . -I "$CORE" -I "$GFX" -o tb_obj0_gateC.vvp \
  tb_obj0_gateC.v \
  "$CORE/jtnslasher_sdram.v" \
  "$CORE/jtnslasher_gfxdec.v" \
  "$SD/jtframe_rom_1slot.v" "$SD/jtframe_rom_2slots.v" \
  "$SD/jtframe_romrq.v" "$SD/jtframe_romrq_bcache.v" "$SD/jtframe_romrq_xscache.v" \
  "$SD/jtframe_ramslot_ctrl.v" \
  "$SD/jtframe_sdram64.v" "$SD/jtframe_sdram64_bank.v" "$SD/jtframe_sdram64_init.v" \
  "$SD/jtframe_sdram64_rfsh.v" "$SD/jtframe_sdram64_latch.v" \
  "$JT/ver/mt48lc16m16a2.v"

"$VVP" tb_obj0_gateC.vvp
