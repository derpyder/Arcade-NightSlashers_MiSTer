#!/bin/bash
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/arm
F=/tmp/ns_full.dis
if [ ! -s "$F" ] || [ dec.bin -nt "$F" ]; then
  arm-none-eabi-objdump -D -b binary -m arm -EL dec.bin | grep -E '^\s*[0-9a-f]+:' > "$F"
fi
echo "lines: $(wc -l < $F)"
echo "===== literal 00100278 (ACE fade src ptr) ====="
grep -nE '\b00100278\b' "$F" | head -40
echo "===== literal 00100103 (task dispatch byte) ====="
grep -nE '\b00100103\b' "$F" | head -40
echo "===== literal 00163080 (ACE fade dst) ====="
grep -nE '\b00163080\b' "$F" | head -40
echo "===== any 001002 (work ram 0x1002xx) ====="
grep -nE '\b001002[0-9a-f][0-9a-f]\b' "$F" | head -60
