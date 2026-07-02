#!/bin/bash
# Validate all four PF layers against captured MAME frames (bit-exact vs gen_layer golden).
#   pf1 @ f360 (8x8 text), pf2 @ f1800 (bank=1), pf3 @ f1800 (gfx2), pf4 @ f1800 (gfx2 bank=2)
for a in "360 pf1" "1800 pf2" "1800 pf3" "1800 pf4"; do
  set -- $a
  echo "##### frame=$1 layer=$2 #####"
  bash /path/to/nightslashers/wsl/run_layer.sh "$1" "$2" 2>&1 \
    | grep -E "layer=|frame compare|COMPILE FAILED|rror|mismatch|->"
done
