#!/bin/bash
# Validate jtnslasher_colmix (full 4PF+2obj+priority+alpha mixer) vs ref_render.py, frame f1800.
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/gfx || exit 1
FRAME=${1:-1800}; PRI=${2:-1}
for f in tb_colmix2.v ../../hdl/jtnslasher_colmix.v; do sed -i 's/\r$//' "$f"; done
echo "=== ref_render: dump layer streams + golden (frame $FRAME, pri $PRI) ==="
python3 ref_render.py "$FRAME" "$PRI" 2>&1 | grep -E "dumped colmix|align dy=-8"
echo "=== iverilog ==="
JTF=/path/to/nightslashers/jtcores/modules/jtframe
iverilog -g2012 -I. -o tb_colmix2.vvp tb_colmix2.v ../../hdl/jtnslasher_colmix.v "$JTF/hdl/ram/jtframe_dual_ram.v" 2>&1 | head -20
[ -f tb_colmix2.vvp ] || { echo "COMPILE FAILED"; exit 1; }
echo "=== run ==="
vvp tb_colmix2.vvp 2>&1 | grep -vE '^(VCD|WARNING.*readmem)' | head