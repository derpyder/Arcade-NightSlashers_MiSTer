#!/bin/bash
# M4 — generate the nslasher MiSTer Quartus project (no real compile yet). Syncs the current HDL/cfg
# from the Windows clone into the WSL build clone (LF), then runs jtcore with a STUB quartus_sh so it
# performs all the real generation (copy_templates + jframe mem/mmr/files syn) without compiling.
set -o pipefail
WINC=/path/to/nightslashers/jtcores/cores/nslasher
JT=$HOME/jtcores
WSLC=$JT/cores/nslasher

echo "=== sync HDL + cfg (Windows clone -> WSL build clone, strip CRLF) ==="
mkdir -p "$WSLC/hdl/amber"
for f in "$WINC"/hdl/*.v; do b=$(basename "$f"); cp "$f" "$WSLC/hdl/$b"; sed -i 's/\r$//' "$WSLC/hdl/$b"; done
for f in "$WINC"/hdl/amber/*.v; do b=$(basename "$f"); cp "$f" "$WSLC/hdl/amber/$b"; sed -i 's/\r$//' "$WSLC/hdl/amber/$b"; done
for f in "$WINC"/cfg/*; do b=$(basename "$f"); [ -f "$f" ] && { cp "$f" "$WSLC/cfg/$b"; sed -i 's/\r$//' "$WSLC/cfg/$b"; }; done
echo "core HDL: $(ls "$WSLC"/hdl/*.v 2>/dev/null | wc -l) ; amber: $(ls "$WSLC"/hdl/amber/*.v 2>/dev/null | wc -l)"

echo "=== stub quartus_sh (generation only; path must contain intelFPGA_lite for jtcore's check) ==="
STUB=/tmp/intelFPGA_lite/quartus/bin; mkdir -p "$STUB"
printf '#!/bin/bash\necho "[stub quartus_sh] $*"\necho "Full Compilation was successful (STUB - not a real build)"\nexit 0\n' > "$STUB/quartus_sh"
chmod +x "$STUB/quartus_sh"
export PATH="$STUB:$PATH"

echo "=== jtcore nslasher -mister (generate; stub compile; no lint) ==="
cd "$JT" || exit 1
source setprj.sh 2>/dev/null
cd "$WSLC" || exit 1
NOLINTER=1 jtcore nslasher -mister 2>&1 | tail -55

echo "=== generated project (cores/nslasher/mister/) ==="
ls -la "$WSLC/mister/" 2>/dev/null
echo "=== qsf: how files/paths are referenced (first 25 file/qip lines) ==="
grep -nE 'SOURCE_FILE|QIP_FILE|SEARCH_PATH|VERILOG_FILE|SDC_FILE' "$WSLC/mister/nslasher.qsf" 2>/dev/null | head -25
echo DONE_GEN
