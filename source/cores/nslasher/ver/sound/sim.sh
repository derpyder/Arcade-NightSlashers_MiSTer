#!/bin/bash
# Night Slashers — standalone sound-subsystem sim (M1.5).
# Usage:  cd $JTROOT && source setprj.sh && cd cores/nslasher/ver/sound && ./sim.sh
# Boots test_snd.hex on the Z80 and self-checks the YM2151/OKI/latch bus path.
set -e
[ -z "$JTFRAME" ] && { echo "source setprj.sh first"; exit 1; }
DEPS=(
  ../../hdl/jtnslasher_snd.v
  "$JTFRAME/hdl/cpu/jtframe_z80.v"
  "$JTFRAME/hdl/cpu/jtframe_z80wait.v"
  "$JTFRAME/hdl/cpu/t80/T80s.v"
  "$JTFRAME/hdl/ram/jtframe_ram.v"
  "$JTFRAME/hdl/ram/jtframe_dual_ram.v"
  "$JTFRAME/hdl/ram/jtframe_dual_nvram.v"
  "$JTFRAME/hdl/sound/jtframe_fir_mono.v"
)
DEPS+=( $JTROOT/modules/jt51/hdl/*.v $JTROOT/modules/jt6295/hdl/*.v )
iverilog -g2012 -o tb_snd.vvp -DSIMULATION -I"$JTFRAME/hdl/inc" tb_snd.v "${DEPS[@]}"
vvp tb_snd.vvp
