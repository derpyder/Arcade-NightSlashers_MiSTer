#!/bin/bash
# M4 freeze repro: boot the real nslasher ARM ROM on a23 + deco156 with cen_arm paced at the
# REAL ~7.08 MHz fractional rate (-DREALCEN) instead of full-speed. Same DUT/ROM/VBL as run_boot.sh;
# only the cen_arm pacing differs. Output -> wsl/run_boot_realcen.log
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
EEPROM="$HOME/jtcores/modules/jteeprom/hdl/jt9346.v"
[ -f "$EEPROM" ] || { echo "MISSING $EEPROM (jteeprom submodule not init'd?)"; exit 1; }
echo "=== iverilog (-DREALCEN: real ~7.08MHz cen_arm pace) ==="
iverilog -g2012 -o tb_boot_realcen.vvp -DSIMULATION -DREALCEN -I$AMBER -I"$JTFRAME/hdl/inc" \
  tb_boot.v sim_models.v ../../hdl/jtnslasher_main.v ../../hdl/jtnslasher_deco156.v \
  "$EEPROM" \
  $AMBER/a23_core.v $AMBER/a23_fetch.v $AMBER/a23_decode.v $AMBER/a23_execute.v \
  $AMBER/a23_alu.v $AMBER/a23_barrel_shift.v $AMBER/a23_multiply.v \
  rb_sim.v $AMBER/a23_coprocessor.v $AMBER/a23_cache.v $AMBER/a23_wishbone.v 2>&1 | head -40
[ -f tb_boot_realcen.vvp ] || { echo "COMPILE FAILED"; exit 1; }
echo "=== run (REALCEN) ==="
LOG=/path/to/nightslashers/wsl/run_boot_realcen.log
vvp tb_boot_realcen.vvp 2>&1 | grep -vE '^(VCD|\$dump)' > "$LOG"
echo "=== done; tail ==="
tail -60 "$LOG"
