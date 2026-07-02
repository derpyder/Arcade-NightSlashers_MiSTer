#!/bin/bash
# Discriminator #2: faithful tb against the plane4-HWSWAP variant of the REAL FSM (the suspected
# pre-fix HW bug). Must turn RED on tiles whose plane4 byte is byteswap-sensitive.
set -e
cd "$(dirname "$0")"
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
SD=$JT/sdram
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx
python3 gen_objfold_real.py >/dev/null
cp -f sdram_bank3_real.hex sdram_bank3.hex
for f in deco56_address.hex deco56_xor.hex deco56_swap.hex deco74_address.hex deco74_xor.hex deco74_swap.hex; do
    [ -e "$f" ] || cp "$GFX/$f" .
done
sed -e 's@assign obj0_rom_data = { o0_p4word\[7:0\], plane_permute(hwswap16(o0_planes)) };@wire [31:0] o0_p4_un = hwswap16(o0_p4word); assign obj0_rom_data = { o0_p4_un[7:0], plane_permute(hwswap16(o0_planes)) };@' \
    "$CORE/jtnslasher_sdram.v" > jtnslasher_sdram_p4swap.v
iverilog -g2012 -I . -I "$CORE" -I "$GFX" -o tb_objfold_real_p4swap.vvp \
  tb_objfold_real.v jtnslasher_sdram_p4swap.v $CORE/jtnslasher_gfxdec.v \
  $SD/jtframe_rom_1slot.v $SD/jtframe_rom_2slots.v $SD/jtframe_romrq.v $SD/jtframe_romrq_bcache.v $SD/jtframe_romrq_xscache.v \
  $SD/jtframe_ramslot_ctrl.v $SD/jtframe_sdram64.v $SD/jtframe_sdram64_bank.v $SD/jtframe_sdram64_init.v \
  $SD/jtframe_sdram64_rfsh.v $SD/jtframe_sdram64_latch.v $JT/ver/mt48lc16m16a2.v
vvp tb_objfold_real_p4swap.vvp
