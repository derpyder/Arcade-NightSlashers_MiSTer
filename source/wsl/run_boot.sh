#!/bin/bash
# M2-int: boot the real (or zero-smoke) nslasher ARM ROM on a23 + deco156.
cd "$HOME/jtcores" || exit 1
source setprj.sh
cp -r /path/to/nightslashers/jtcores/cores/nslasher/. cores/nslasher/ 2>/dev/null || true
find cores/nslasher -type f \( -name '*.v' -o -name '*.py' -o -name '*.s' -o -name '*.sh' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
cd cores/nslasher/ver/arm || exit 1
ROMDIR=/path/to/nightslashers/roms
if [ -f "$ROMDIR/ly-00.1f" ] && [ -f "$ROMDIR/ly-01.2f" ]; then
  echo "=== building raw_rom.hex from REAL nslashers ROMs (ly-00.1f + ly-01.2f) ==="
  python3 make_rom.py "$ROMDIR/ly-00.1f" "$ROMDIR/ly-01.2f" raw_rom.hex
elif [ ! -f raw_rom.hex ]; then
  echo "(no real ROMs + no raw_rom.hex -> ZERO smoke rom)"
  python3 -c "import sys; sys.stdout.write(('00000000\n')*262144)" > raw_rom.hex
fi
awk '/synthesis translate_off/{s=1} /synthesis translate_on/{s=0;next} !s' ../../hdl/amber/a23_register_bank.v > rb_sim.v
AMBER=../../hdl/amber
# jt9346 = 93C46 EEPROM (also contains jt9346_dual_ram). Path is jteeprom submodule under jtcores root.
EEPROM="$HOME/jtcores/modules/jteeprom/hdl/jt9346.v"
[ -f "$EEPROM" ] || { echo "MISSING $EEPROM (jteeprom submodule not init'd?)"; exit 1; }
echo "=== iverilog ==="
# EXTRA_DEFS: optional extra -D defines for ad-hoc experiments (e.g. EXTRA_DEFS=-DFOO bash run_boot.sh).
EXTRA_DEFS="${EXTRA_DEFS:-}"
iverilog -g2012 -o tb_boot.vvp -DSIMULATION $EXTRA_DEFS -I$AMBER -I"$JTFRAME/hdl/inc" \
  tb_boot.v sim_models.v ../../hdl/jtnslasher_main.v ../../hdl/jtnslasher_deco156.v \
  "$EEPROM" \
  $AMBER/a23_core.v $AMBER/a23_fetch.v $AMBER/a23_decode.v $AMBER/a23_execute.v \
  $AMBER/a23_alu.v $AMBER/a23_barrel_shift.v $AMBER/a23_multiply.v \
  rb_sim.v $AMBER/a23_coprocessor.v $AMBER/a23_cache.v $AMBER/a23_wishbone.v 2>&1 | head -40
[ -f tb_boot.vvp ] || { echo "COMPILE FAILED"; exit 1; }
echo "=== run ==="
# Full filtered output written to a Windows-readable log (no head/SIGPIPE truncation), then show the head.
LOG=/path/to/nightslashers/wsl/run_boot.log
vvp tb_boot.vvp 2>&1 | grep -vE '^(VCD|\$dump)' > "$LOG"
head -120 "$LOG"; echo "...(full log: wsl/run_boot.log)..."; tail -40 "$LOG"
