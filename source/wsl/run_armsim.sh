#!/bin/bash
# M2a: assemble the ARM test program, build the a23 bring-up tb with iverilog, run.
cd "$HOME/jtcores" || exit 1
source setprj.sh
CORE=nslasher
cp -r /path/to/nightslashers/jtcores/cores/$CORE/. cores/$CORE/ 2>/dev/null || true
find cores/$CORE -type f \( -name '*.v' -o -name '*.s' -o -name '*.hex' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true

SIM="$HOME/jtcores/cores/$CORE/ver/arm"
# strip the sim-only `synthesis translate_off` cpu_export debug block from the WSL build copy
RB="$HOME/jtcores/cores/$CORE/hdl/amber/a23_register_bank.v"
awk '/synthesis translate_off/{s=1} /synthesis translate_on/{s=0;next} !s' "$RB" > "$RB.tmp" && mv "$RB.tmp" "$RB"
cd "$SIM" || { echo "no ver/arm"; exit 1; }

echo "=== assemble ARM test program ==="
arm-none-eabi-as -march=armv2a -o test_arm.o test_arm.s || { echo "ASM FAILED"; exit 1; }
arm-none-eabi-objcopy -O binary test_arm.o test_arm.bin
python3 - <<'PY' > test_arm.hex
import struct
d=open('test_arm.bin','rb').read()
d+=b'\x00'*((-len(d))%4)
for i in range(0,len(d),4):
    print('%08x'%struct.unpack('<I',d[i:i+4])[0])
PY
echo "program words:"; cat test_arm.hex

AMBER=../../hdl/amber
DEPS=(
  ../../hdl/jtnslasher_main.v
  sim_models.v
  $AMBER/a23_core.v $AMBER/a23_fetch.v $AMBER/a23_decode.v $AMBER/a23_execute.v
  $AMBER/a23_alu.v $AMBER/a23_barrel_shift.v $AMBER/a23_multiply.v
  $AMBER/a23_register_bank.v $AMBER/a23_coprocessor.v $AMBER/a23_cache.v
  $AMBER/a23_wishbone.v
)
echo "=== iverilog compile ==="
iverilog -g2012 -o tb_main.vvp -DSIMULATION -I$AMBER -I"$JTFRAME/hdl/inc" \
  tb_main.v "${DEPS[@]}" 2>&1 | head -50
if [ ! -f tb_main.vvp ]; then echo "COMPILE FAILED"; exit 1; fi
echo "=== run ==="
vvp tb_main.vvp 2>&1 | grep -vE '^(VCD info|\$dump)' | head -120
echo "=== done ==="
