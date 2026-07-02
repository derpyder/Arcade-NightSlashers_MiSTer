#!/bin/bash
# Decrypt the real nslasher ROM and disassemble a byte-address range (default the 0xbd4..0xc00 loop).
set -e
ROMDIR=/path/to/nightslashers/roms
WORKDIR=/path/to/nightslashers/jtcores/cores/nslasher/ver/arm
cd "$WORKDIR"
LO=${1:-0x2e0}     # first word to print
HI=${2:-0x310}     # last  word to print
START=${3:-0xb80}  # objdump byte range
STOP=${4:-0xc40}
python3 dec_dump.py "$ROMDIR/ly-00.1f" "$ROMDIR/ly-01.2f" "$LO" "$HI"
echo "=== objdump ARM (little-endian) $START..$STOP ==="
arm-none-eabi-objdump -D -b binary -m arm -EL \
  --start-address="$START" --stop-address="$STOP" dec.bin | sed -n '/<.data>:/,$p'
