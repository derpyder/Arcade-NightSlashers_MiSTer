#!/bin/bash
# M4 fix round 1: deco_consts.vh + deco hex (gfxdec), drop memory_configuration.v, sync jt6295/jteeprom.
set -o pipefail
WSL=$HOME/jtcores
WINB=/path/to/nightslashers/jtcores
WM=$WINB/cores/nslasher/mister
GFX=$WINB/cores/nslasher/ver/gfx
HDL=$WINB/cores/nslasher/hdl

echo "=== 1. generate deco tables (down_pass.py emit) ==="
cd "$GFX" && ROMDIR=/path/to/nightslashers/roms python3 down_pass.py emit | tail -2

echo "=== 2. deco_consts.vh -> hdl (SEARCH_PATH) ; deco*.hex -> mister build dir ==="
cp "$GFX/deco_consts.vh" "$HDL/deco_consts.vh"
sed -i 's/\r$//' "$HDL/deco_consts.vh"
for h in deco56_address deco56_xor deco56_swap deco74_address deco74_xor deco74_swap; do
  cp "$GFX/$h.hex" "$WM/$h.hex"
done
echo "deco hex in mister/: $(ls "$WM"/deco*.hex 2>/dev/null | wc -l) ; deco_consts.vh: $([ -e "$HDL/deco_consts.vh" ] && echo yes)"

echo "=== 3. drop memory_configuration.v from files.qip ==="
sed -i '/memory_configuration.v/d' "$WM/files.qip"
echo "memory_configuration refs left: $(grep -c memory_configuration "$WM/files.qip" || true)"

echo "=== 4. sync jt6295 + jteeprom hdl -> Windows clone ==="
for m in jt6295 jteeprom; do
  mkdir -p "$WINB/modules/$m/hdl"
  cp -r "$WSL/modules/$m/hdl/." "$WINB/modules/$m/hdl/" 2>/dev/null
  echo "$m hdl: $(ls "$WINB/modules/$m/hdl"/*.v 2>/dev/null | wc -l)"
done
echo DONE_FIX1
