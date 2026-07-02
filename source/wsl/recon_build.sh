#!/bin/bash
# Recon: understand the jtcores Quartus build flow for nslasher.
cd $HOME/jtcores 2>/dev/null || cd "$HOME/jtcores" || exit 1
source setprj.sh 2>/dev/null
echo "JTROOT=$JTROOT  JTFRAME=$JTFRAME"
echo "=== jtcore on PATH? quartus_sh? ==="
which jtcore 2>&1
which quartus_sh 2>&1
echo "=== jtcore usage / first lines ==="
jtcore 2>&1 | head -45
echo "=== jtcore-funcs: quartus invocation + build dir ==="
grep -nE 'quartus_sh|--flow|\.qsf|\.qpf|\.qip|QUARTUS|qartus|cd .*mister|mkdir|jtframe (mem|cfgstr|files|qsf|sdram)' "$JTFRAME/bin/jtcore-funcs" 2>/dev/null | head -35
echo "=== mister.qsf template: how files are pulled ==="
grep -nE 'SOURCE_FILE|QIP_FILE|set_global|SDC_FILE|jtframe|core|VERILOG' "$JTFRAME/target/mister/mister.qsf" 2>/dev/null | head -20
echo "=== mister.qpf head ==="
head -10 "$JTFRAME/target/mister/mister.qpf" 2>/dev/null
