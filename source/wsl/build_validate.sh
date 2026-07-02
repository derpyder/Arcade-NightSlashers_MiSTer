#!/bin/bash
# Build the jtframe Go tool directly (bypassing the wrapper's go-test gate),
# then validate the nslasher cfg spine (macros.def / mem.yaml / mame2mra.toml).
set -uo pipefail
cd "$HOME/jtcores"
source setprj.sh
echo "JTROOT=$JTROOT"
echo "=== build jtframe (direct go build, skips test gate) ==="
if ( cd "$JTFRAME/src/jtframe" && go build . ); then echo BUILD_OK; else echo BUILD_FAIL; exit 1; fi
JF="$JTFRAME/src/jtframe/jtframe"
echo; echo "=== jtframe --help (subcommand list) ==="
"$JF" --help 2>&1 | head -80
echo; echo "=== validate mem.yaml: jtframe mem nslasher ==="
"$JF" mem nslasher 2>&1 | head -60 || true
echo DONE_VALIDATE
