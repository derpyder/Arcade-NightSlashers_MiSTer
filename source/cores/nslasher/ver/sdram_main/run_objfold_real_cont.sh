#!/bin/bash
# Faithful seam sim WITH SDRAM contention (BA0/1/2 competing reads + refresh) to vary obj0 latency.
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
# JTFRAME_SIM_SDRAM_NONSTOP: don't $finish on the bcache's address-change assertion for the
# self-driving contention banks (their addr_ok is permanently high, which the assertion warns about
# but is a LEGAL use mode); SIMULATION/JTFRAME_SDRAM_LARGE as the real build defines them.
# JTFRAME_SIM_ROMRQ_NOCHECK disables the bcache's *requester-protocol* sim assertion (sim-only checker,
# not DUT logic). The obj0 path obeys the protocol; the deliberately-aggressive contention generators
# need not, and their assertion spam must not perturb the obj0 timing under test.
iverilog -g2012 -DSIMULATION -DJTFRAME_SIM_SDRAM_NONSTOP -DJTFRAME_SIM_ROMRQ_NOCHECK -I . -I "$CORE" -I "$GFX" -o tb_objfold_real_cont.vvp \
  tb_objfold_real_cont.v $CORE/jtnslasher_sdram.v $CORE/jtnslasher_gfxdec.v \
  $SD/jtframe_rom_1slot.v $SD/jtframe_rom_2slots.v $SD/jtframe_romrq.v $SD/jtframe_romrq_bcache.v $SD/jtframe_romrq_xscache.v \
  $SD/jtframe_ramslot_ctrl.v $SD/jtframe_sdram64.v $SD/jtframe_sdram64_bank.v $SD/jtframe_sdram64_init.v \
  $SD/jtframe_sdram64_rfsh.v $SD/jtframe_sdram64_latch.v $JT/ver/mt48lc16m16a2.v
vvp tb_objfold_real_cont.vvp
