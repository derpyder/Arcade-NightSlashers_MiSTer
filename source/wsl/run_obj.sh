#!/bin/bash
# Validate jtnslasher_obj (one sprite layer) vs gen_obj_golden, for a captured MAME frame.
#   usage: run_obj.sh <frame> <spr0|spr1>     (spr0=gfx3 5bpp, spr1=gfx4 4bpp)
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/gfx || exit 1
FRAME=${1:-1800}; LAYER=${2:-spr1}
JTF=/path/to/nightslashers/jtcores/modules/jtframe
for f in tb_obj.v ../../hdl/jtnslasher_obj.v; do sed -i 's/\r$//' "$f"; done
echo "=== gen golden + cfg ($FRAME $LAYER) ==="
python3 gen_obj_golden.py "$FRAME" "$LAYER" || exit 1
echo "=== iverilog ==="
iverilog -g2012 -I. -o tb_obj.vvp tb_obj.v ../../hdl/jtnslasher_obj.v \
  "$JTF/hdl/ram/jtframe_obj_buffer.v" "$JTF/hdl/ram/jtframe_dual_ram.v" 2>&1 | head -30
[ -f tb_obj.vvp ] || { echo "COMPILE FAILED"; exit 1; }
echo "=== run ==="
vvp tb_obj.vvp 2>&1 | grep -vE '^(VCD|WARNING.*readmem)' | head
echo "=== compare ==="
python3 cmp_obj.py
