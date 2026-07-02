#!/bin/bash
M=$HOME/jtcores/cores/nslasher/mister
MD=/path/to/nightslashers/mame-dump
cp "$M/jtnslasher.qsf" "$MD/nslasher.qsf.txt"
cp "$M/jtnslasher.qpf" "$MD/nslasher.qpf.txt"
cp "$M/files.qip" "$MD/files.qip.txt"
echo "=== qsf: QIP/SDC/SOURCE references ==="
grep -nE 'QIP_FILE|SDC_FILE|SOURCE_FILE|SEARCH_PATH|VERILOG|VHDL|SYSTEMVERILOG|GLOBAL_ASSIGNMENT -name (TOP|FAMILY|DEVICE)' "$M/jtnslasher.qsf"
echo "=== files.qip: line count + path style + amber presence ==="
wc -l "$M/files.qip"
echo "-- first 6 + last 4 file lines --"
grep -nE 'FILE' "$M/files.qip" | head -6
grep -nE 'FILE' "$M/files.qip" | tail -4
echo "-- amber / a23 in files.qip? --"; grep -c -iE 'amber|a23' "$M/files.qip"
echo "-- does it reference the core HDL (jtnslasher)? --"; grep -nE 'jtnslasher' "$M/files.qip" | head
echo "=== sanity: do a few referenced paths exist in the WINDOWS clone? ==="
WB=/path/to/nightslashers/jtcores
for p in modules/jtframe/target/mister/hdl/mister_top.v modules/jtframe/hdl/jtframe.v cores/nslasher/hdl/jtnslasher_game.v; do
  [ -e "$WB/$p" ] && echo "OK  $p" || echo "MISSING  $p"
done
echo DONE_INSPECT
