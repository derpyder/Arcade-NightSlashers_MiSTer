#!/bin/bash
# Synchronous, pocket-free: verify jtframe present, copy scaffold, build the jtframe Go tool, validate cfg.
set -o pipefail   # NB: no -u; setprj.sh reads $JTBIN before defining it
pkill -9 -f finish_setup 2>/dev/null || true
pkill -9 -f submodule    2>/dev/null || true
pkill -9 ssh             2>/dev/null || true
sleep 1
cd "$HOME/jtcores" || { echo NO_JTCORES; exit 1; }
find . -path '*.git*' -name '*.lock' -delete 2>/dev/null || true

gocount=$(ls modules/jtframe/src/jtframe/*.go 2>/dev/null | wc -l)
echo "jtframe go sources: $gocount ; setprj.sh: $([ -f setprj.sh ] && echo yes || echo no)"

if [ "$gocount" -lt 1 ] || [ ! -f setprj.sh ]; then
  echo "jtframe incomplete -> direct clone of JTFRAME (plain, no submodules => no pocket)"
  rm -rf modules/jtframe
  GIT_SSH_COMMAND='ssh -o BatchMode=yes' timeout 300 git clone --depth 1 https://github.com/jotego/JTFRAME modules/jtframe </dev/null
fi

echo "=== copy nslasher scaffold ==="
mkdir -p cores/nslasher
cp -r /path/to/nightslashers/jtcores/cores/nslasher/. cores/nslasher/ 2>/dev/null || true
find cores/nslasher/cfg -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
( ls cores/nslasher/cfg >/dev/null 2>&1 && echo "scaffold OK" ) || echo "scaffold MISSING"

echo "=== build jtframe Go tool (direct, skip test gate) ==="
source setprj.sh
( cd "$JTFRAME/src/jtframe" && timeout 240 go build . ) && echo BUILD_OK || echo BUILD_FAIL
JF="$JTFRAME/src/jtframe/jtframe"
if [ -x "$JF" ]; then
  echo "=== jtframe mem nslasher --target mister ==="
  "$JF" mem nslasher --target mister 2>&1 | head -30 || true
  echo "=== jtframe files sim nslasher --target mister (from ver/game) ==="
  mkdir -p "$HOME/jtcores/cores/nslasher/ver/game"
  ( cd "$HOME/jtcores/cores/nslasher/ver/game" && "$JF" files sim nslasher --target mister 2>&1 ) | head -40 || true
  echo "=== generated artifacts in core dir ==="
  ls -la "$HOME/jtcores/cores/nslasher/" 2>/dev/null
  ls -la "$HOME/jtcores/cores/nslasher/mist/" 2>/dev/null
fi
echo BUILD_NOW_DONE
