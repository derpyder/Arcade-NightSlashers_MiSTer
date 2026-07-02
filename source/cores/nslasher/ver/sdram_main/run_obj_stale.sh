#!/bin/bash
# REAL engine + REAL fold FSM + behavioral irregular-latched-ok slot (contention model).
set -e
cd "$(dirname "$0")"
JT=/path/to/nightslashers/jtcores/modules/jtframe/hdl
RAM=$JT/ram
CORE=/path/to/nightslashers/jtcores/cores/nslasher/hdl
GFX=/path/to/nightslashers/jtcores/cores/nslasher/ver/gfx
for f in deco56_address.hex deco56_xor.hex deco56_swap.hex deco74_address.hex deco74_xor.hex deco74_swap.hex; do
    [ -e "$f" ] || cp "$GFX/$f" .
done
iverilog -g2012 -DSIMULATION -I . -I "$CORE" -I "$GFX" -o tb_obj_stale.vvp \
  tb_obj_stale.v $CORE/jtnslasher_sdram.v $CORE/jtnslasher_gfxdec.v $CORE/jtnslasher_obj.v \
  $RAM/jtframe_obj_buffer.v $RAM/jtframe_dual_ram.v
echo "=== clean-ish (LAT 2..4) ==="; vvp tb_obj_stale.vvp +SEED=1 +MIN=2 +MAX=4   2>&1 | grep -v 'WARNING' | tail -8
echo "=== contended (LAT 2..30) ==="
for s in 1 2 3 7 13; do vvp tb_obj_stale.vvp +SEED=$s +MIN=2 +MAX=30 2>&1 | grep -E 'consumes=|UNIFORM|CLEAN|DATA WRONG|MISMATCH' | head -6; echo "  --- seed $s done ---"; done

echo "=== extreme long latency (LAT 8..120) ==="
for s in 1 5 9; do vvp tb_obj_stale.vvp +SEED=$s +MIN=8 +MAX=120 2>&1 | grep -E 'consumes=|UNIFORM|CLEAN|DATA WRONG|MISMATCH' | head -6; done

# GLITCHY: ok randomly drops mid-hold (attacks fresh-ok edge detector + 2nd-ok consume)
iverilog -g2012 -DSIMULATION -DGLITCH -I . -I "$CORE" -I "$GFX" -o tb_obj_stale_g.vvp \
  tb_obj_stale.v $CORE/jtnslasher_sdram.v $CORE/jtnslasher_gfxdec.v $CORE/jtnslasher_obj.v \
  $RAM/jtframe_obj_buffer.v $RAM/jtframe_dual_ram.v
echo "=== GLITCHY ok (drops randomly mid-hold), LAT 2..30 ==="
for s in 1 2 3 7 13 42; do timeout 90 vvp tb_obj_stale_g.vvp +SEED=$s +MIN=2 +MAX=30 2>&1 | grep -E 'consumes=|UNIFORM|CLEAN|DATA WRONG|TIMEOUT' | head -3; echo "  --- seed $s done ---"; done
