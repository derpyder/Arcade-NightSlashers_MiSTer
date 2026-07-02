#!/bin/bash
J="$HOME/jtcores"
cd "$J/cores/nslasher" || exit 1
echo "=== find all generated artifacts (.f, .qip, .inc, _sdram.v) ==="
find . \( -name '*.f' -o -name '*.qip' -o -name '*.inc' -o -name '*_sdram.v' \) -newer cfg/files.yaml 2>/dev/null
find . \( -name '*.f' -o -name '*.qip' -o -name '*.inc' -o -name '*_sdram.v' \) 2>/dev/null
echo
echo "=== game.f (verilog file list for sim) ==="
find . -name 'game.f' -exec ls -l {} \; -exec head -40 {} \;
echo
echo "=== look for any new sim files ==="
find . -newer cfg/files.yaml -type f 2>/dev/null
echo
echo "=== verilator availability ==="
command -v verilator && verilator --version | head -1 || echo "verilator NOT installed"
