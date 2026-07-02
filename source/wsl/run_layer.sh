#!/bin/bash
# Validate one PF layer of jtnslasher_tilemap against a captured MAME frame.
#   usage: run_layer.sh <frame> <pf1|pf2|pf3|pf4>
# gen_layer.py builds golden_pxl.hex + layer_cfg.vh (pf/gfx + tile8/bank/scroll from the caps),
# tb_layer.v renders via the RTL, cmp_frame.py diffs bit-exact.
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/gfx || exit 1
FRAME=${1:-1800}; LAYER=${2:-pf2}
CAPS=/path/to/nightslashers/mame-dump/caps
JTF=/path/to/nightslashers/jtcores/modules/jtframe
for f in tb_layer.v ../../hdl/jtnslasher_tilemap.v; do sed -i 's/\r$//' "$f"; done
echo "=== gen golden + cfg  (frame $FRAME, $LAYER) ==="
python3 gen_layer.py "$CAPS" "$FRAME" "$LAYER" || exit 1
echo "=== iverilog ==="
iverilog -g2012 -I. -DSIMULATION -o tb_layer.vvp tb_layer.v ../../hdl/jtnslasher_tilemap.v \
  "$JTF/hdl/video/jtframe_linebuf.v" "$JTF/hdl/ram/jtframe_rpwp_ram.v" 2>&1 | head -30
[ -f tb_layer.vvp ] || { echo "COMPILE FAILED"; exit 1; }
echo "=== run ==="
vvp tb_layer.vvp 2>&1 | grep -vE '^(VCD|WARNING.*readmem)' | head
echo "=== compare ==="
python3 cmp_frame.py
