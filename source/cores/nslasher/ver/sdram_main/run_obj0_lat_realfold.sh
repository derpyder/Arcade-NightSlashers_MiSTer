#!/bin/bash
# Measure the REAL implemented obj0 DENSE-FOLD 2-read FSM latency on real SDRAM.
# DUT = real jtnslasher_sdram.v + real jtframe_rom_2slots BA3 (SLOT0_DOUBLE) + mt48lc16m16a2.
# Pass CONTEND=1 to inject BA1(CPU)+BA2(PF) traffic.
set -e
cd "$(dirname "$0")"
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
SD=$JT/sdram
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx

# regenerate REAL-address preload + test vectors (writes objfold_real_addr.hex + sdram_bank3_real.hex)
python3 gen_objfold_real.py

# deco tables for the (unused) gfxdec instances
for f in deco56_address.hex deco56_xor.hex deco56_swap.hex \
         deco74_address.hex deco74_xor.hex deco74_swap.hex; do
    [ -e "$f" ] || cp "$GFX/$f" .
done

# the mt48lc16m16a2 model loads bank3 from the fixed name sdram_bank3.hex
cp -f sdram_bank3_real.hex sdram_bank3.hex

DEFS=""
SUF="idle"
if [ "$CONTEND" = "1" ]; then DEFS="-DCONTEND"; SUF="contend"; fi

iverilog -g2012 -I . -I "$CORE" -I "$GFX" $DEFS -o tb_obj0_lat_realfold_${SUF}.vvp \
  tb_obj0_lat_realfold.v \
  $CORE/jtnslasher_sdram.v \
  $CORE/jtnslasher_gfxdec.v \
  $SD/jtframe_rom_1slot.v $SD/jtframe_rom_2slots.v \
  $SD/jtframe_romrq.v $SD/jtframe_romrq_bcache.v $SD/jtframe_romrq_xscache.v \
  $SD/jtframe_ramslot_ctrl.v \
  $SD/jtframe_sdram64.v $SD/jtframe_sdram64_bank.v $SD/jtframe_sdram64_init.v \
  $SD/jtframe_sdram64_rfsh.v $SD/jtframe_sdram64_latch.v \
  $JT/ver/mt48lc16m16a2.v

vvp tb_obj0_lat_realfold_${SUF}.vvp
