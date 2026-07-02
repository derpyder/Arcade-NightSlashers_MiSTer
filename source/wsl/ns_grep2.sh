#!/bin/bash
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/arm
F=/tmp/ns_full.dis
if [ ! -s "$F" ] || [ dec.bin -nt "$F" ]; then
  arm-none-eabi-objdump -D -b binary -m arm -EL dec.bin | grep -E '^\s*[0-9a-f]+:' > "$F"
fi
echo "lines: $(wc -l < $F)"
for P in "$@"; do
  echo "===== grep: $P ====="
  grep -nE "$P" "$F" | head -80
done
