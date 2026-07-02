#!/bin/bash
# Regenerate the SDRAM module + mem_ports.inc after a mem.yaml change, copy to the Windows build dir.
set -o pipefail
WSL=$HOME/jtcores
WINC=/path/to/nightslashers/jtcores/cores/nslasher
WSLC=$WSL/cores/nslasher
cp "$WINC/cfg/mem.yaml" "$WSLC/cfg/mem.yaml"; sed -i 's/\r$//' "$WSLC/cfg/mem.yaml"
cd "$WSL" || exit 1
source setprj.sh 2>/dev/null
JF="$JTFRAME/src/jtframe/jtframe"
echo "=== jtframe mem nslasher --target mister ==="
"$JF" mem nslasher --target mister 2>&1 | tail -5
cp "$WSLC/mister/jtnslasher_game_sdram.v" "$WINC/mister/jtnslasher_game_sdram.v"
cp "$WSLC/mister/mem_ports.inc" "$WINC/mister/mem_ports.inc"
echo "=== ram bus ports in regenerated mem_ports.inc ==="
grep -nE 'ram_data|main_dout|ram_addr|ram_dsn|\bdsn\b' "$WINC/mister/mem_ports.inc" | head
echo DONE_REGEN
