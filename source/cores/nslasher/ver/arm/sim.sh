#!/bin/bash
# Night Slashers — a23 (ARM) main-CPU bring-up sim (M2a).
# Usage:  cd $JTROOT && source setprj.sh && cd cores/nslasher/ver/arm && ./sim.sh
# Boots test_arm.s on the Amber a23 and self-checks ALU/LDR/STR + the soundlatch path.
set -e
[ -z "$JTFRAME" ] && { echo "source setprj.sh first"; exit 1; }
AMBER=../../hdl/amber
# behavioral cache SRAMs (sim_models.v) replace the altsyncram versions;
# strip the sim-only translate_off cpu_export debug block into a local copy (synth keeps the original)
awk '/synthesis translate_off/{s=1} /synthesis translate_on/{s=0;next} !s' "$AMBER/a23_register_bank.v" > rb_sim.v
# assemble the ARM test program -> 32-bit LE word hex
arm-none-eabi-as -march=armv2a -o test_arm.o test_arm.s
arm-none-eabi-objcopy -O binary test_arm.o test_arm.bin
python3 - <<'PY' > test_arm.hex
import struct
d=open('test_arm.bin','rb').read(); d+=b'\x00'*((-len(d))%4)
for i in range(0,len(d),4): print('%08x'%struct.unpack('<I',d[i:i+4])[0])
PY
# main.v now instantiates deco156 + jt9346 + (DIAG) vidprobe — compile them too, else elaboration fails.
EE=$JTFRAME/../jteeprom/hdl
iverilog -g2012 -o tb_main.vvp -DSIMULATION -I$AMBER -I"$JTFRAME/hdl/inc" \
  tb_main.v sim_models.v ../../hdl/jtnslasher_main.v \
  ../../hdl/jtnslasher_deco156.v ../../hdl/jtnslasher_vidprobe.v \
  $EE/jt9346.v $EE/jt9346_16b8b.v \
  $AMBER/a23_core.v $AMBER/a23_fetch.v $AMBER/a23_decode.v $AMBER/a23_execute.v \
  $AMBER/a23_alu.v $AMBER/a23_barrel_shift.v $AMBER/a23_multiply.v \
  rb_sim.v $AMBER/a23_coprocessor.v $AMBER/a23_cache.v $AMBER/a23_wishbone.v
vvp tb_main.vvp
