#!/bin/bash
# FIX C2 / task #9 gate: per-tile flip + colour&7 across both tile sizes x all 4 enable combos.
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/gfx || exit 1
JTF=/path/to/nightslashers/jtcores/modules/jtframe
for f in tb_flip.v ../../hdl/jtnslasher_tilemap.v; do sed -i 's/\r$//' "$f"; done
FAIL=0
for T8 in 0 1; do
  for FE in 0 1 2 3; do
    python3 gen_flip_test.py $T8 $FE >/dev/null || { echo "GEN FAILED"; exit 1; }
    iverilog -g2012 -I. -DSIMULATION -o tb_flip.vvp tb_flip.v ../../hdl/jtnslasher_tilemap.v \
      "$JTF/hdl/video/jtframe_linebuf.v" "$JTF/hdl/ram/jtframe_rpwp_ram.v" 2>&1 | head -5
    [ -f tb_flip.vvp ] || { echo "COMPILE FAILED"; exit 1; }
    R=$(vvp tb_flip.vvp 2>/dev/null | grep -E "match|RESULT|mismatch")
    echo "tile8=$T8 flip_en=$FE : $R" | tr '\n' ' '; echo
    echo "$R" | grep -q "RESULT: PASS" || FAIL=1
    rm -f tb_flip.vvp
  done
done
[ $FAIL -eq 0 ] && echo "=== ALL 8 FLIP CONFIGS PASS ===" || echo "=== FLIP FAILURES ==="
