#!/bin/bash
# Faithfulness discriminator: run the FAITHFUL tb against the BUGGY FSM (must turn RED).
set -e
cd "$(dirname "$0")"
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
SD=$JT/sdram
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx

python3 gen_objfold_real.py >/dev/null
cp -f sdram_bank3_real.hex sdram_bank3.hex
for f in deco56_address.hex deco56_xor.hex deco56_swap.hex \
         deco74_address.hex deco74_xor.hex deco74_swap.hex; do
    [ -e "$f" ] || cp "$GFX/$f" .
done

# rename the buggy module to jtnslasher_sdram so the tb binds to it
sed 's/jtnslasher_sdram_BUGGY/jtnslasher_sdram/' jtnslasher_sdram_BUGGY.v > jtnslasher_sdram_buggyrenamed.v

iverilog -g2012 -I . -I "$CORE" -I "$GFX" -o tb_objfold_real_buggy.vvp \
  tb_objfold_real.v \
  jtnslasher_sdram_buggyrenamed.v \
  $CORE/jtnslasher_gfxdec.v \
  $SD/jtframe_rom_1slot.v $SD/jtframe_rom_2slots.v \
  $SD/jtframe_romrq.v $SD/jtframe_romrq_bcache.v $SD/jtframe_romrq_xscache.v \
  $SD/jtframe_ramslot_ctrl.v \
  $SD/jtframe_sdram64.v $SD/jtframe_sdram64_bank.v $SD/jtframe_sdram64_init.v \
  $SD/jtframe_sdram64_rfsh.v $SD/jtframe_sdram64_latch.v \
  $JT/ver/mt48lc16m16a2.v

vvp tb_objfold_real_buggy.vvp
