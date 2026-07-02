#!/bin/bash
J="$HOME/jtcores"; D=/path/to/nightslashers
rm -rf $D/nslasher-gen
mkdir -p $D/nslasher-gen
cp -r $J/cores/nslasher/mist $J/cores/nslasher/mister $J/cores/nslasher/pocket 2>/dev/null $D/nslasher-gen/ 2>/dev/null || true
find $D/nslasher-gen -type f
