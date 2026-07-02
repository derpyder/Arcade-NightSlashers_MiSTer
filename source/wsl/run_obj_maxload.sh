#!/bin/bash
# Synthetic 127/140-sprite worst-case line sweep (the full-screen fire-effect comb sizing, §9.5).
# Sweeps fetch latency at the CURRENT 1-line budget (3072) and at a 2-line-lead budget (6144).
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/gfx || exit 1
JTF=/path/to/nightslashers/jtcores/modules/jtframe
for f in tb_obj_maxload.v ../../hdl/jtnslasher_obj.v ../../hdl/jtnslasher_obj_buffer.v; do sed -i 's/\r$//' "$f"; done
python3 gen_maxload.py || exit 1
echo "=== budget 3072 (today: 1-line lead) ==="
for LAT in 1 8 14 20 28 36 44; do
  iverilog -g2012 -I. -DSIMULATION -DLAT=$LAT -DLINEBUDGET=3072 -o _ml.vvp tb_obj_maxload.v \
    ../../hdl/jtnslasher_obj.v ../../hdl/jtnslasher_obj_buffer.v "$JTF/hdl/ram/jtframe_dual_ram.v" 2>&1 | head -3
  vvp _ml.vvp 2>/dev/null | grep "LAT="
done
echo "=== budget 6144 (a 2-line-lead engine) ==="
for LAT in 14 20 28 36 44; do
  iverilog -g2012 -I. -DSIMULATION -DLAT=$LAT -DLINEBUDGET=6144 -o _ml.vvp tb_obj_maxload.v \
    ../../hdl/jtnslasher_obj.v ../../hdl/jtnslasher_obj_buffer.v "$JTF/hdl/ram/jtframe_dual_ram.v" 2>&1 | head -3
  vvp _ml.vvp 2>/dev/null | grep "LAT="
done
rm -f _ml.vvp
