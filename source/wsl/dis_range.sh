#!/bin/bash
# Disassemble arbitrary byte ranges of the decrypted ARM ROM (dec.bin).
# Usage: dis_range.sh <start> <stop> [<start2> <stop2> ...]
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/arm
while [ $# -ge 2 ]; do
  S=$1; E=$2; shift 2
  echo "========== $S .. $E =========="
  arm-none-eabi-objdump -D -b binary -m arm -EL --start-address="$S" --stop-address="$E" dec.bin \
    | grep -E '^\s*[0-9a-f]+:'
done
