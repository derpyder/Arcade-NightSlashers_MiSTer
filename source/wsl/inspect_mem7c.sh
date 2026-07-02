#!/bin/bash
cd "$HOME/jtcores" || exit 1
source setprj.sh
JF="$JTFRAME/src/jtframe/jtframe"
echo "=== jtframe mem nslasher --target mister (full stdout+stderr) ==="
"$JF" mem nslasher --target mister
echo "EXIT=$?"
echo; echo "=== artifacts generated under cores/nslasher (newest first) ==="
find cores/nslasher -newermt '-3 minutes' -type f \( -name '*.v' -o -name '*.h' -o -name '*.vh' -o -name '*.f' -o -name '*.qip' \) 2>/dev/null | sort
echo; echo "=== look for the SDRAM bank/offset macros in any generated header ==="
grep -rIl 'BA3_START\|obj0lo\|OBJ0HI\|JTFRAME_BA2_START' cores/nslasher 2>/dev/null | while read f; do echo "FOUND in $f"; done
echo; echo "=== game.f (sim filelist) ==="
F=$(find cores/nslasher -name 'game.f' 2>/dev/null | head -1)
echo "game.f = $F"
[ -n "$F" ] && { echo "lines: $(wc -l < "$F")"; echo "--- first 25 ---"; sed -n '1,25p' "$F"; }
echo DONE
