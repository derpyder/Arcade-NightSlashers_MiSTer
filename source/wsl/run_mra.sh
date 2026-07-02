#!/bin/bash
# 7c-3d — generate the Night Slashers MRA via `jframe mra` (MAME 0.284 xml).
# Syncs the updated cfg from the Windows clone, installs the nslasher mame.xml, runs jframe mem+mra.
set -o pipefail
WINC=/path/to/nightslashers/jtcores/cores/nslasher
XML=/path/to/nightslashers/mame-dump/nslasher_custom.xml   # sprite ROMs reassigned to distinct regions
cd "$HOME/jtcores" || exit 1
source setprj.sh 2>/dev/null
JF="$JTFRAME/src/jtframe/jtframe"
[ -x "$JF" ] || { echo "jtframe binary missing at $JF"; exit 1; }

echo "=== sync cfg (Windows clone -> build clone) ==="
mkdir -p cores/nslasher/cfg
for f in mame2mra.toml macros.def mem.yaml files.yaml; do
  [ -f "$WINC/cfg/$f" ] && { cp "$WINC/cfg/$f" "cores/nslasher/cfg/$f"; sed -i 's/\r$//' "cores/nslasher/cfg/$f"; }
done
echo "mame2mra.toml -> $(wc -l < cores/nslasher/cfg/mame2mra.toml) lines"

echo "=== install nslasher mame.xml (backup the big one once) ==="
[ -f doc/mame.xml.bak ] || cp doc/mame.xml doc/mame.xml.bak
cp "$XML" doc/mame.xml; sed -i 's/\r$//' doc/mame.xml
echo "nslasher machines in mame.xml: $(grep -c 'machine name=\"nslasher' doc/mame.xml)"

echo "=== jtframe mem nslasher --target mister (refresh macro/sdram context) ==="
"$JF" mem nslasher --target mister 2>&1 | tail -4

echo "=== jtframe mra -n nslasher ==="
"$JF" mra -n nslasher
RC=$?
echo "jtframe mra exit=$RC"

echo "=== generated .mra files ==="
find "$HOME/jtcores" -iname '*.mra' -newermt '-5 min' 2>/dev/null

echo "=== byte-exact check: assemble the Over Sea .mra from real ROMs vs golden ==="
MD=/path/to/nightslashers/mame-dump
cp "$HOME/jtcores/release/mra/_alternatives/_Night Slashers/"*Over*Sea*.mra "$MD/nslashers.mra" 2>/dev/null
GFX=$WINC/ver/gfx
ROMDIR=/path/to/nightslashers/roms python3 "$GFX/mra_assemble.py" "$MD/nslashers.mra"
echo DONE_MRA
