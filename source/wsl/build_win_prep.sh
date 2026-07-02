#!/bin/bash
# M4 — prepare a Windows-Quartus-buildable project on D: from the WSL-generated project.
# Syncs the missing jt51 submodule, copies the generated mister/ project to the Windows clone,
# rewrites the $HOME/jtcores absolute paths to the Windows path, adds the amber a23 + the SDC.
set -o pipefail
WSL=$HOME/jtcores
WINB=/path/to/nightslashers/jtcores        # Windows clone (WSL view)
WINP='/path/to/nightslashers/jtcores'          # Windows clone (Quartus/Windows view)
SM=$WSL/cores/nslasher/mister                       # generated project (WSL)
WM=$WINB/cores/nslasher/mister                      # build dir (Windows clone)

echo "=== 1. sync missing jt51 hdl -> Windows clone ==="
mkdir -p "$WINB/modules/jt51/hdl"
cp -r "$WSL/modules/jt51/hdl/." "$WINB/modules/jt51/hdl/" 2>/dev/null
echo "jt51 hdl in Windows clone: $(ls "$WINB"/modules/jt51/hdl/*.v 2>/dev/null | wc -l)"

echo "=== 2. verify framework tcl/sdc exist in Windows clone ==="
for f in modules/jtframe/target/mister/hdl/sys/sys.tcl \
         modules/jtframe/target/mister/hdl/sys/sys_analog.tcl \
         modules/jtframe/target/mister/hdl/sys/build_id.tcl; do
  [ -e "$WINB/$f" ] && echo "OK  $f" || echo "MISSING  $f  (syncing)"
  [ -e "$WINB/$f" ] || { mkdir -p "$(dirname "$WINB/$f")"; cp "$WSL/$f" "$WINB/$f"; }
done
# sys_top.sdc lives in the target syn/ template; jtcore copies it into the build dir
SDC=$(find "$WSL/modules/jtframe/target/mister" -name 'sys_top.sdc' | head -1)
echo "sys_top.sdc source: $SDC"

echo "=== 3. copy generated project -> Windows mister/ ==="
mkdir -p "$WM"
cp "$SM/jtnslasher.qpf" "$SM/jtnslasher.qsf" "$SM/files.qip" "$SM/cfgstr.hex" \
   "$SM/jtnslasher_game_sdram.v" "$SM/mem_ports.inc" "$WM/"
[ -n "$SDC" ] && cp "$SDC" "$WM/sys_top.sdc"
for h in font0 logodata logomap fir20k fir2_69 firjt49 jt6295_up4 jt6295_up4_soft; do
  [ -e "$SM/$h.hex" ] && cp -L "$SM/$h.hex" "$WM/$h.hex"
done
echo "mister/ now: $(ls "$WM" | wc -l) files ; hex: $(ls "$WM"/*.hex 2>/dev/null | wc -l)"

echo "=== 4. rewrite $HOME/jtcores -> $WINP (qsf + files.qip) ==="
sed -i "s#$HOME/jtcores#$WINP#g" "$WM/files.qip" "$WM/jtnslasher.qsf"
echo "remaining $HOME refs: $(grep -c $HOME "$WM/files.qip" "$WM/jtnslasher.qsf" 2>/dev/null | paste -sd+)"

echo "=== 5. add amber a23 synth set + search path ==="
AMB="$WINP/cores/nslasher/hdl/amber"
for m in a23_core a23_fetch a23_decode a23_execute a23_alu a23_barrel_shift a23_multiply \
         a23_register_bank a23_coprocessor a23_cache a23_wishbone sram_byte_en sram_line_en memory_configuration; do
  echo "set_global_assignment -name VERILOG_FILE $AMB/$m.v" >> "$WM/files.qip"
done
echo "set_global_assignment -name SEARCH_PATH \"$AMB\"" >> "$WM/jtnslasher.qsf"
echo "files.qip: $(wc -l < "$WM/files.qip") lines, amber refs: $(grep -c amber "$WM/files.qip")"
echo DONE_PREP
