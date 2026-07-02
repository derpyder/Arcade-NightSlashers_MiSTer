#!/bin/bash
DEC=/path/to/nightslashers/jtcores/cores/nslasher/ver/arm/dec.bin
dis() {
  arm-none-eabi-objdump -D -b binary -m arm -EL --start-address="$1" --stop-address="$2" "$DEC" | grep -E '^\s*[0-9a-f]+:'
}
echo "=== handler bit1 @0x1aa78 ==="
dis 0x1aa78 0x1ab40
echo "=== handler bit2 @0x1abc0 ==="
dis 0x1abc0 0x1ac70
echo "=== handler bit4 @0x1ac70 ==="
dis 0x1ac70 0x1ad20
echo "=== handler bit8 @0x1ad20 ==="
dis 0x1ad20 0x1adc0
