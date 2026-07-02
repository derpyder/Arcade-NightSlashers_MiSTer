#!/bin/bash
cd "$HOME/jtcores" || exit 1
source setprj.sh
JF="$JTFRAME/src/jtframe/jtframe"
echo "=== jtframe --help ==="
"$JF" --help 2>&1 | head -40
echo
echo "=== jtframe files --help ==="
"$JF" files --help 2>&1
echo
echo "=== jtframe files sim nslasher --target mister (from core dir) ==="
cd "$HOME/jtcores/cores/nslasher"
"$JF" files sim nslasher --target mister 2>&1 | head -40
echo "--- looking for .f files after ---"
find . -name '*.f' 2>/dev/null
echo
echo "=== jtframe files sim nslasher --target mister (from ver/game) ==="
mkdir -p "$HOME/jtcores/cores/nslasher/ver/game"
cd "$HOME/jtcores/cores/nslasher/ver/game"
"$JF" files sim nslasher --target mister 2>&1 | head -40
echo "--- looking for .f files in ver/game ---"
ls -la
