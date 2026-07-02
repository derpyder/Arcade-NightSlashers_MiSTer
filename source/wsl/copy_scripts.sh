#!/bin/bash
cd $HOME/jtcores 2>/dev/null || cd "$HOME/jtcores"
source setprj.sh 2>/dev/null
JF="$JTFRAME/bin"
MD=/path/to/nightslashers/mame-dump
cp "$JF/jtcore" "$MD/jtcore.txt"
cp "$JF/jtcore-funcs" "$MD/jtcore-funcs.txt"
echo "done: jtcore=$(wc -l < "$MD/jtcore.txt") jtcore-funcs=$(wc -l < "$MD/jtcore-funcs.txt") lines"
echo "PRJPATH/PRJ usage in jtcore (how it sets the build dir):"
grep -nE 'PRJPATH|PRJ=|corename|cores/' "$JF/jtcore" | head -20
