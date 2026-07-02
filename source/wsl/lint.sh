#!/bin/bash
# Verilator lint of our M1 HDL using the jtframe-generated game.f.
# We focus on syntax errors in OUR files (jtnslasher_*.v) — framework
# files are well-tested upstream.
cd "$HOME/jtcores" || exit 1
source setprj.sh
CORE=nslasher
COREDIR="$HOME/jtcores/cores/$CORE"

# Parse macros.def into +define+NAME=VAL flags (skip blanks/comments/[sections])
DEFINES=""
while IFS= read -r line; do
  l="${line%%#*}"; l="$(echo "$l" | xargs)"
  case "$l" in
    ""|"["*) continue ;;
    *=*)  DEFINES+=" +define+${l%%=*}=${l#*=}" ;;
    *)    DEFINES+=" +define+$l" ;;
  esac
done < "$COREDIR/cfg/macros.def"

# Add include dirs for the includes our files use
INCS="-I$COREDIR/hdl -I$COREDIR/mister -I$JTFRAME/hdl/inc -I$JTFRAME/target/mister/hdl"

# Useful sim macros (cores assume these for sim contexts)
SIMDEFS="+define+SIMULATION +define+VERILATOR +define+NOMAIN +define+NOVIDEO"

echo "=== DEFINES (from macros.def) ==="
echo "$DEFINES"
echo
echo "=== verilator --lint-only on game.f ==="
verilator --lint-only --timing -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
  --top-module jtnslasher_game \
  $INCS $DEFINES $SIMDEFS \
  -f "$COREDIR/ver/game/game.f" 2>&1 | head -120
echo "rc=$?"
