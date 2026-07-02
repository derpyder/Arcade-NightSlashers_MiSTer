#!/bin/bash
# Lint jtnslasher_game.v with the include path resolved.
# Strategy: lint our 2 files + their deps + the generated mem_ports.inc.
# Stub framework macros that aren't in macros.def but are referenced upstream.
cd "$HOME/jtcores" || exit 1
source setprj.sh
COREDIR="$HOME/jtcores/cores/nslasher"

DEPS=(
  "$COREDIR/hdl/jtnslasher_game.v"
  "$COREDIR/hdl/jtnslasher_snd.v"
  "$JTFRAME/hdl/cpu/jtframe_z80.v"
  "$JTFRAME/hdl/cpu/jtframe_z80wait.v"
  "$JTFRAME/hdl/ram/jtframe_ram.v"
  "$JTFRAME/hdl/ram/jtframe_dual_ram.v"
  "$JTFRAME/hdl/ram/jtframe_dual_nvram.v"
  "$JTFRAME/hdl/cpu/t80/T80s.v"
)
DEPS+=( $(ls $JTROOT/modules/jt51/hdl/*.v) )
DEPS+=( $(ls $JTROOT/modules/jt6295/hdl/*.v) )

# Macros: from macros.def + framework-mandatory stubs
DEFINES=""
while IFS= read -r line; do
  l="${line%%#*}"; l="$(echo "$l" | xargs)"
  case "$l" in
    ""|"["*) continue ;;
    *=*)  DEFINES+=" +define+${l%%=*}=${l#*=}" ;;
    *)    DEFINES+=" +define+$l" ;;
  esac
done < "$COREDIR/cfg/macros.def"

# Per-target-include framework macros (these are normally set by the target's macros.def)
DEFINES+=" +define+JTFRAME_MCLK=48000000"
DEFINES+=" +define+JTFRAME_MEMGEN"

# Includes: per-core mister/ for mem_ports.inc, jtframe inc for game_ports.inc, plus mister target
INCS="-I$COREDIR/mister -I$JTFRAME/hdl/inc -I$JTFRAME/target/mister/hdl"

echo "=== lint top=jtnslasher_game  files=${#DEPS[@]} ==="
verilator --lint-only -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
  -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-REDEFMACRO \
  --top-module jtnslasher_game \
  $DEFINES +define+SIMULATION +define+VERILATOR \
  $INCS \
  "${DEPS[@]}" 2>&1 | head -80
echo "rc=$?"
