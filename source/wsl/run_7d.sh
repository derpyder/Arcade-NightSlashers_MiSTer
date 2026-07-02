#!/bin/bash
# 7d — validate the integrated game top. Sync cfg+hdl, regen the SDRAM module (jtframe mem), resolve the
# core file list (jtframe files), then verilator-lint the WHOLE game wiring via an explicit file list
# (mirrors M1 lint_game.sh: macros from macros.def + framework stubs; amber/jt deps + altsyncram via
# ver/arm/sim_models.v). The pass criterion = no errors originating in jtnslasher_game.v.
set -o pipefail
cd "$HOME/jtcores" || { echo NO_JTCORES; exit 1; }
SRC=/path/to/nightslashers/jtcores/cores/nslasher
COREDIR="$HOME/jtcores/cores/nslasher"
echo "=== sync cfg/ + hdl/ ==="
mkdir -p cores/nslasher/cfg cores/nslasher/hdl/amber cores/nslasher/ver/arm
cp -f "$SRC"/cfg/* cores/nslasher/cfg/
cp -f "$SRC"/hdl/*.v cores/nslasher/hdl/
cp -f "$SRC"/hdl/amber/*.v cores/nslasher/hdl/amber/
cp -f "$SRC"/ver/arm/sim_models.v cores/nslasher/ver/arm/ 2>/dev/null
find cores/nslasher/cfg cores/nslasher/hdl -type f | xargs -r sed -i 's/\r$//' 2>/dev/null
source setprj.sh
JF="$JTFRAME/src/jtframe/jtframe"

echo; echo "=== jtframe mem nslasher --target mister ==="
"$JF" mem nslasher --target mister 2>&1 | head -8; echo "MEM_EXIT=${PIPESTATUS[0]}"
cp -f cores/nslasher/mister/jtnslasher_game_sdram.v cores/nslasher/mister/mem_ports.inc "$SRC"/mister/ 2>/dev/null

echo; echo "=== jtframe files sim nslasher --target mister ==="
mkdir -p cores/nslasher/ver/game
( cd cores/nslasher/ver/game && "$JF" files sim nslasher --target mister 2>&1 | head -8 )

echo; echo "=== verilator lint (explicit file list, top=jtnslasher_game) ==="
# strip a23_register_bank's sim-only translate_off (cpu_export) like the boot sim
awk '/synthesis translate_off/{s=1} /synthesis translate_on/{s=0;next} !s' "$COREDIR/hdl/amber/a23_register_bank.v" > /tmp/rb_sim.v
AMBER="$COREDIR/hdl/amber"
DEPS=(
  "$COREDIR/hdl/jtnslasher_game.v" "$COREDIR/hdl/jtnslasher_main.v" "$COREDIR/hdl/jtnslasher_snd.v"
  "$COREDIR/hdl/jtnslasher_vmem.v" "$COREDIR/hdl/jtnslasher_video.v" "$COREDIR/hdl/jtnslasher_tilemap.v"
  "$COREDIR/hdl/jtnslasher_obj.v" "$COREDIR/hdl/jtnslasher_colmix.v" "$COREDIR/hdl/jtnslasher_sdram.v"
  "$COREDIR/hdl/jtnslasher_gfxdec.v" "$COREDIR/hdl/jtnslasher_dwnld.v" "$COREDIR/hdl/jtnslasher_deco156.v"
  "$AMBER/a23_core.v" "$AMBER/a23_fetch.v" "$AMBER/a23_decode.v" "$AMBER/a23_execute.v"
  "$AMBER/a23_alu.v" "$AMBER/a23_barrel_shift.v" "$AMBER/a23_multiply.v" "/tmp/rb_sim.v"
  "$AMBER/a23_coprocessor.v" "$AMBER/a23_cache.v" "$AMBER/a23_wishbone.v"
  "$JTFRAME/hdl/video/jtframe_vtimer.v" "$JTFRAME/hdl/video/jtframe_linebuf.v"
  "$JTFRAME/hdl/ram/jtframe_dual_ram.v" "$JTFRAME/hdl/ram/jtframe_obj_buffer.v"
  "$JTFRAME/hdl/ram/jtframe_rpwp_ram.v" "$JTFRAME/hdl/ram/jtframe_ram.v" "$JTFRAME/hdl/ram/jtframe_dual_nvram.v"
  "$JTFRAME/hdl/cpu/jtframe_z80.v" "$JTFRAME/hdl/cpu/jtframe_z80wait.v" "$JTFRAME/hdl/cpu/t80/T80s.v"
  "$COREDIR/ver/arm/sim_models.v" "$JTROOT/modules/jteeprom/hdl/jt9346.v"
)
DEPS+=( $(ls $JTROOT/modules/jt51/hdl/*.v) $(ls $JTROOT/modules/jt6295/hdl/*.v) )
DEFINES=""
while IFS= read -r line; do l="${line%%#*}"; l="$(echo "$l" | xargs)"
  case "$l" in ""|"["*) continue;; *=*) DEFINES+=" +define+${l%%=*}=${l#*=}";; *) DEFINES+=" +define+$l";; esac
done < "$COREDIR/cfg/macros.def"
DEFINES+=" +define+JTFRAME_MCLK=48000000 +define+JTFRAME_MEMGEN"
ROMDIR=/path/to/nightslashers/roms python3 "$SRC/ver/gfx/down_pass.py" emit >/dev/null 2>&1  # ensure deco_consts.vh
INCS="-I$COREDIR/mister -I$JTFRAME/hdl/inc -I$JTFRAME/target/mister/hdl -I$AMBER -I$SRC/ver/gfx -I$COREDIR/ver/arm"
verilator --lint-only -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
  -Wno-REDEFMACRO -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
  --top-module jtnslasher_game $DEFINES +define+SIMULATION +define+VERILATOR $INCS "${DEPS[@]}" 2>&1 \
  | grep -vE "^-|Verilator: (Built|Walltime)" | head -50
echo "=== errors in jtnslasher_game.v specifically ==="
verilator --lint-only -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
  -Wno-REDEFMACRO -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
  --top-module jtnslasher_game $DEFINES +define+SIMULATION +define+VERILATOR $INCS "${DEPS[@]}" 2>&1 \
  | grep -E "jtnslasher_game.v" | head -30
echo DONE_7D
