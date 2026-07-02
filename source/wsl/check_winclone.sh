#!/bin/bash
# Check whether the Windows clone has every file files.qip references (so we can build there).
QIP=$HOME/jtcores/cores/nslasher/mister/files.qip
WB=/path/to/nightslashers/jtcores
miss=0; tot=0
while IFS= read -r line; do
  f=$(printf '%s\n' "$line" | grep -oE '$HOME/jtcores/[^ "]+\.(v|sv|vhd)')
  [ -z "$f" ] && continue
  tot=$((tot+1))
  w="${f/\/home\/user\/jtcores/$WB}"
  if [ ! -e "$w" ]; then miss=$((miss+1)); [ $miss -le 20 ] && echo "MISSING: ${f#$HOME/jtcores/}"; fi
done < "$QIP"
echo "=== files.qip references $tot HDL files; $miss missing in the Windows clone ==="
