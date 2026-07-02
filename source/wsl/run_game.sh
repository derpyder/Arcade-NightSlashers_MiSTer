#!/bin/bash
# 7e — full-game boot+render sim: build ROMs, compile the integrated game + all deps, boot the ARM,
# capture a rendered frame. Run from ver/gfx so the relative $readmemh (raw_rom/snd/oki + deco tables)
# resolve. Output: ver/gfx/frame_game.hex.
set -o pipefail
SRC=/path/to/nightslashers/jtcores/cores/nslasher
GFX=$SRC/ver/gfx; GAME=$SRC/ver/game; HDL=$SRC/hdl; AMBER=$HDL/amber
cd "$HOME/jtcores" 2>/dev/null || true; source setprj.sh 2>/dev/null
NSROM=/path/to/nightslashers/roms   # set AFTER setprj.sh (which owns $ROM)
JTF=$SRC/../../modules/jtframe
EEPROM="$HOME/jtcores/modules/jteeprom/hdl/jt9346.v"
[ -f "$EEPROM" ] || EEPROM=$(find /path/to/nightslashers/jtcores/modules -name jt9346.v | head -1)
cd "$GFX" || exit 1
for f in "$GAME/tb_game.v" $HDL/*.v; do sed -i 's/\r$//' "$f" 2>/dev/null; done

echo "=== build ROM hex ==="
python3 "$SRC/ver/arm/make_rom.py" "$NSROM/ly-00.1f" "$NSROM/ly-01.2f" raw_rom.hex | tail -1
python3 -c "d=open('$NSROM/sndprg.17l','rb').read();open('snd_rom.hex','w').write(''.join('%02x\n'%b for b in d));print('snd_rom.hex',len(d))"
python3 -c "d=open('$NSROM/mbh-10.14l','rb').read();open('oki1.hex','w').write(''.join('%02x\n'%b for b in d));print('oki1.hex',len(d))"
python3 -c "d=open('$NSROM/mbh-11.16l','rb').read();open('oki2.hex','w').write(''.join('%02x\n'%b for b in d));print('oki2.hex',len(d))"
ROMDIR=$NSROM python3 down_pass.py emit | tail -1
awk '/synthesis translate_off/{s=1} /synthesis translate_on/{s=0;next} !s' "$AMBER/a23_register_bank.v" > rb_sim.v

# macros from macros.def + framework stubs
DEFS=""
while IFS= read -r line; do l="${line%%#*}"; l="$(echo "$l" | xargs)"
  case "$l" in ""|"["*) continue;; *=*) DEFS+=" -D${l%%=*}=${l#*=}";; *) DEFS+=" -D$l";; esac
done < "$SRC/cfg/macros.def"
DEFS+=" -DJTFRAME_MCLK=48000000 -DJTFRAME_MEMGEN -DSIMULATION"

echo "=== iverilog ==="
iverilog -g2012 -o "$GFX/tb_game.vvp" $DEFS \
  -I"$AMBER" -I"$JTF/hdl/inc" -I"$JTF/target/mister/hdl" -I"$SRC/mister" -I"$GFX" \
  "$GAME/tb_game.v" \
  $HDL/jtnslasher_game.v $HDL/jtnslasher_main.v $HDL/jtnslasher_snd.v $HDL/jtnslasher_vmem.v \
  $HDL/jtnslasher_video.v $HDL/jtnslasher_tilemap.v $HDL/jtnslasher_obj.v $HDL/jtnslasher_colmix.v \
  $HDL/jtnslasher_sdram.v $HDL/jtnslasher_gfxdec.v $HDL/jtnslasher_dwnld.v $HDL/jtnslasher_deco156.v \
  $AMBER/a23_core.v $AMBER/a23_fetch.v $AMBER/a23_decode.v $AMBER/a23_execute.v $AMBER/a23_alu.v \
  $AMBER/a23_barrel_shift.v $AMBER/a23_multiply.v rb_sim.v $AMBER/a23_coprocessor.v $AMBER/a23_cache.v \
  $AMBER/a23_wishbone.v "$EEPROM" "$SRC/ver/arm/sim_models.v" \
  "$JTF/hdl/video/jtframe_vtimer.v" "$JTF/hdl/video/jtframe_linebuf.v" \
  "$JTF/hdl/ram/jtframe_dual_ram.v" "$JTF/hdl/ram/jtframe_obj_buffer.v" "$JTF/hdl/ram/jtframe_rpwp_ram.v" \
  "$JTF/hdl/ram/jtframe_ram.v" "$JTF/hdl/ram/jtframe_dual_nvram.v" \
  "$JTF/hdl/cpu/jtframe_z80.v" "$JTF/hdl/cpu/jtframe_z80wait.v" "$JTF/hdl/cpu/t80/T80s.v" \
  $(ls $JTROOT/modules/jt51/hdl/*.v) $(ls $JTROOT/modules/jt6295/hdl/*.v) 2>&1 | head -40
[ -f "$GFX/tb_game.vvp" ] || { echo "COMPILE FAILED"; exit 1; }

echo "=== run ==="
LOG=/path/to/nightslashers/wsl/run_game.log
vvp "$GFX/tb_game.vvp" 2>&1 | grep -vE '^(VCD|\$dump|WARNING.*readmem)' > "$LOG"
tail -20 "$LOG"
echo DONE_7E
