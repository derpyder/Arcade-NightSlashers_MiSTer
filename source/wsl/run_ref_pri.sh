#!/bin/bash
# Sweep deco32_pri 0..3 through the reference renderer, report screenshot match (dy=-8).
cd /path/to/nightslashers/jtcores/cores/nslasher/ver/gfx || exit 1
F=${1:-1800}
for p in 0 1 2 3; do
  r=$(python3 ref_render.py "$F" "$p" 2>&1 | grep "dy=-8")
  echo "pri=$p -> $r"
done
