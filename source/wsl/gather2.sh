#!/bin/bash
J="$HOME/jtcores"; D=/path/to/nightslashers
cp "$J/modules/jtframe/hdl/inc/jtframe_common_ports.inc" "$D/" 2>/dev/null && echo "copied common_ports.inc"
find "$J/modules/jtframe/hdl" -name 'jtframe_sysz80*.v' -exec cp {} "$D/" \; -print 2>/dev/null
echo "=== jt51 instantiation example (real core) ==="
f=$(grep -rl 'jt51 u_' "$J/cores"/*/hdl 2>/dev/null | head -1)
echo "from: $f"
[ -n "$f" ] && awk '/jt51 u_/{p=1} p{print} p&&/\);/{exit}' "$f"
echo "=== jt6295 instantiation example (real core) ==="
g=$(grep -rl 'jt6295 u_' "$J/cores"/*/hdl 2>/dev/null | head -1)
echo "from: $g"
[ -n "$g" ] && awk '/jt6295 u_/{p=1} p{print} p&&/\);/{exit}' "$g"
echo "=== jtframe_sysz80 ports ==="
sz=$(find "$J/modules/jtframe/hdl" -name 'jtframe_sysz80.v' | head -1)
echo "from: $sz"
[ -n "$sz" ] && sed -n '1,90p' "$sz"
echo GATHER_DONE
