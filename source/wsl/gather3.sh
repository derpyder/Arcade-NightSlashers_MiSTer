#!/bin/bash
J="$HOME/jtcores"; D=/path/to/nightslashers
echo "=== sysz80 files ==="
find "$J/modules/jtframe/hdl" -iname '*sysz80*' 2>/dev/null
echo "=== all z80-named files ==="
find "$J/modules/jtframe/hdl" -iname '*z80*' 2>/dev/null
echo "=== cores using jtframe_sysz80 ==="
grep -rl 'jtframe_sysz80' "$J/cores"/*/hdl 2>/dev/null | head -5
z=$(grep -rl 'jtframe_sysz80' "$J/cores"/*/hdl 2>/dev/null | head -1)
echo "--- example instantiation from: $z ---"
[ -n "$z" ] && awk '/jtframe_sysz80/{p=1} p{print} p&&/\);/{exit}' "$z"
echo "=== copy sysz80 module(s) + Z80/YM2151 reference sound modules ==="
find "$J/modules/jtframe/hdl" -iname '*sysz80*' -exec cp {} "$D/" \; 2>/dev/null
for c in s16 s16b rastan tora wc twin16; do
  for f in "$J/cores/$c/hdl/"*snd*.v "$J/cores/$c/hdl/"*sound*.v; do
    [ -f "$f" ] && cp "$f" "$D/ref_${c}_$(basename $f)" && echo "copied $c: $(basename $f)"
  done
done
[ -f "$J/cores/ajax/hdl/jtajax_sound.v" ] && cp "$J/cores/ajax/hdl/jtajax_sound.v" "$D/ref_ajax_sound.v" && echo "copied ajax sound"
echo GATHER3_DONE
