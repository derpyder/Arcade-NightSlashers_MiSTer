#!/bin/bash
# Focused lint of jtnslasher_snd.v with only its actual dependencies (Z80 + jt51 + jt6295).
# Avoids the framework infrastructure to surface OUR syntax errors directly.
cd "$HOME/jtcores" || exit 1
source setprj.sh
COREDIR="$HOME/jtcores/cores/nslasher"

# Just the deps jtnslasher_snd needs:
DEPS=(
  "$COREDIR/hdl/jtnslasher_snd.v"
  "$JTFRAME/hdl/cpu/jtframe_z80.v"
  "$JTFRAME/hdl/cpu/jtframe_z80wait.v"
  "$JTFRAME/hdl/ram/jtframe_ram.v"
  "$JTFRAME/hdl/ram/jtframe_dual_ram.v"
  "$JTFRAME/hdl/ram/jtframe_dual_nvram.v"
  "$JTFRAME/hdl/sound/jtframe_fir_mono.v"
  "$JTFRAME/hdl/cpu/t80/T80s.v"
)
DEPS+=( $(ls $JTROOT/modules/jt51/hdl/*.v) )
DEPS+=( $(ls $JTROOT/modules/jt6295/hdl/*.v) )

echo "=== lint top=jtnslasher_snd  files=${#DEPS[@]} ==="
verilator --lint-only -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
  -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
  --top-module jtnslasher_snd \
  +define+SIMULATION +define+VERILATOR \
  -I"$JTFRAME/hdl/inc" \
  "${DEPS[@]}" 2>&1 | head -80
echo "rc=$?"
