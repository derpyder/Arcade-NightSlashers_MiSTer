#!/bin/bash
# 7c-1: validate the render-format SDRAM topology (macros.def + mem.yaml).
# Syncs ONLY cfg/ from the Windows clone (no ver/ clobber), builds jtframe, runs mem + files.
set -o pipefail
cd "$HOME/jtcores" || { echo NO_JTCORES; exit 1; }
SRC=/path/to/nightslashers/jtcores/cores/nslasher
echo "=== sync cfg/ Windows -> WSL ==="
mkdir -p cores/nslasher/cfg
cp -f "$SRC"/cfg/* cores/nslasher/cfg/
find cores/nslasher/cfg -type f -exec sed -i 's/\r$//' {} +
ls -la cores/nslasher/cfg/

source setprj.sh
JF="$JTFRAME/src/jtframe/jtframe"
if [ ! -x "$JF" ]; then
  echo "=== build jtframe (direct go build) ==="
  ( cd "$JTFRAME/src/jtframe" && go build . ) && echo BUILD_OK || { echo BUILD_FAIL; exit 1; }
fi

echo; echo "=== jtframe mem nslasher --target mister ==="
"$JF" mem nslasher --target mister 2>&1 | head -80
echo "MEM_EXIT=${PIPESTATUS[0]}"

echo; echo "=== generated mem header (bank/offset macros) ==="
find cores/nslasher -name 'mem.h' -o -name '*_cfg.v' 2>/dev/null | while read f; do echo "--- $f ---"; sed -n '1,80p' "$f"; done

echo; echo "=== jtframe files sim nslasher --target mister ==="
mkdir -p cores/nslasher/ver/game
( cd cores/nslasher/ver/game && "$JF" files sim nslasher --target mister 2>&1 | head -30 )
echo DONE_7C1
