#!/bin/bash
# M2b: sync core, generate golden, run the deco156 unit test.
cd "$HOME/jtcores" || exit 1
source setprj.sh
cp -r /path/to/nightslashers/jtcores/cores/nslasher/. cores/nslasher/ 2>/dev/null || true
find cores/nslasher -type f \( -name '*.v' -o -name '*.py' -o -name '*.sh' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
cd cores/nslasher/ver/deco156 || { echo "no ver/deco156"; exit 1; }
echo "=== generate golden (python port of MAME decrypt) ==="
python3 gold.py
echo "=== iverilog ==="
iverilog -g2012 -o tb.vvp tb_deco156.v ../../hdl/jtnslasher_deco156.v 2>&1 | head -30
[ -f tb.vvp ] || { echo "COMPILE FAILED"; exit 1; }
echo "=== run ==="
vvp tb.vvp 2>&1 | head -40
