#!/bin/bash
J="$HOME/jtcores"
echo "=== where is 'module jtframe_sysz80' defined? ==="
grep -rn 'module jtframe_sysz80' "$J/modules/jtframe/hdl" 2>/dev/null
echo
echo "=== first lines of jtframe_z80.v ==="
head -30 "$J/modules/jtframe/hdl/cpu/jtframe_z80.v"
echo
echo "=== jtframe_z80.yaml contents ==="
cat "$J/modules/jtframe/hdl/cpu/jtframe_z80.yaml" 2>/dev/null
