#!/bin/bash
# Stage the built .rbf + the 3 byte-exact MRAs for the cab.
REL=/path/to/nightslashers/releases
RBF=/path/to/nightslashers/jtcores/cores/nslasher/mister/output_files/jtnslasher.rbf
mkdir -p "$REL"
cp "$RBF" "$REL/jtnslasher.rbf"
cp "$HOME/jtcores/release/mra/Night Slashers"*.mra "$REL/" 2>/dev/null
cp "$HOME/jtcores/release/mra/_alternatives/_Night Slashers/Night Slashers"*.mra "$REL/" 2>/dev/null
echo "=== staged in $REL ==="
ls -la "$REL"
echo "rbf md5: $(md5sum "$REL/jtnslasher.rbf" | cut -d' ' -f1)"
