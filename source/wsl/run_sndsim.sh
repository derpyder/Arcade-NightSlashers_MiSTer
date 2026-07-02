#!/bin/bash
# M1.5 sound sim: sync core from Windows, compile jtnslasher_snd tb with iverilog, run.
cd "$HOME/jtcores" || exit 1
source setprj.sh
CORE=nslasher
# sync authored files Windows -> WSL
cp -r /path/to/nightslashers/jtcores/cores/$CORE/. cores/$CORE/ 2>/dev/null || true
find cores/$CORE/cfg cores/$CORE/hdl cores/$CORE/ver -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true

SIMDIR="$HOME/jtcores/cores/$CORE/ver/sound"
cd "$SIMDIR" || { echo "no ver/sound"; exit 1; }

DEPS=(
  "$HOME/jtcores/cores/$CORE/hdl/jtnslasher_snd.v"
  "$JTFRAME/hdl/cpu/jtframe_z80.v"
  "$JTFRAME/hdl/cpu/jtframe_z80wait.v"
  "$JTFRAME/hdl/cpu/t80/T80s.v"
  "$JTFRAME/hdl/ram/jtframe_ram.v"
  "$JTFRAME/hdl/ram/jtframe_dual_ram.v"
  "$JTFRAME/hdl/ram/jtframe_dual_nvram.v"
  "$JTFRAME/hdl/sound/jtframe_fir_mono.v"
)
DEPS+=( $(ls $JTROOT/modules/jt51/hdl/*.v) )
DEPS+=( $(ls $JTROOT/modules/jt6295/hdl/*.v) )

echo "=== iverilog compile (${#DEPS[@]} deps + tb) ==="
iverilog -g2012 -grelative-include -o tb_snd.vvp \
  -DSIMULATION -I"$JTFRAME/hdl/inc" \
  tb_snd.v "${DEPS[@]}" 2>&1 | head -60
if [ ! -f tb_snd.vvp ]; then echo "COMPILE FAILED"; exit 1; fi
echo "=== run (vvp) ==="
vvp tb_snd.vvp 2>&1 | grep -vE '^(VCD|\$dump)' | head -150
echo "=== done ==="
ls -la tb_snd.vcd 2>/dev/null
