# Building Night Slashers from source

This tree is a **drop-in core for [jtcores](https://github.com/jotego/jtcores)** (jotego's arcade
framework). It is not a standalone project.

## Layout
- `cores/nslasher/hdl/` — the core RTL: Amber ARM bridge + DE156 decrypt, DECO16IC tilemaps
  (per-tile flip), dual DECO52 sprite engines, the Ace colour mixer (fades, variable alpha,
  joint-8bpp), vmem, sound (Z80 + jt51 + 2x jt6295), SDRAM adapter + at-fetch deco56/74 decrypt.
- `cores/nslasher/cfg/` — jtframe configuration (mem.yaml, macros.def, mame2mra.toml).
  ⚠ Audio channel gains are hand-set in `mister/jtnslasher_game_sdram.v` (see the comment there);
  mem.yaml documents intent but only applies on regeneration.
- `cores/nslasher/ver/` — the simulation fleet: golden-model generators (Python) + iverilog
  testbenches. Golden **data** is not shipped (it derives from the game ROMs); the generators
  rebuild it from your own ROM set. Colour-mixer tbs accept `+CEN8` to run the hardware's real
  pixel-clock-enable ratio — always test both.
- Specification reference: the MAME `deco32` driver family — use the modern (GPL-2.0+/BSD)
  sources at github.com/mamedev/mame (`src/mame/dataeast/deco32*.cpp`, `deco_ace.cpp`,
  `machine/deco156.cpp`, `video/deco16ic.cpp`), tag `mame0284`. (Older-license MAME files are
  intentionally not vendored here.)
- `cores/nslasher/mister/` — Quartus project files incl. the generated game wrapper and the
  deco56/74 decrypt tables (derived from MAME's decocrpt tables).
- `wsl/` — the generate/build/test helper scripts.

## Build (as used for the releases)
1. Clone jtcores, place `cores/nslasher` into it, vendor JTFRAME per jtcores docs.
2. Generation runs under Linux/WSL (`jtframe mem nslasher --target mister` etc. — see
   `wsl/build_gen.sh`); synthesis was done with Quartus 17.0.2 Lite on Windows:
   `quartus_sh --flow compile jtnslasher` inside `cores/nslasher/mister/`.
3. ROMs: build the MRAs in `../releases/` against MAME 0.284 sets. The MRAs encode this core's
   custom SDRAM layout — do not regenerate them with stock tooling.

Notes:
- `hdl/dbg_golden.vh` ships as a ZEROED placeholder (the real table embeds words of the game
  program). The on-cab ROM-path debugger is diagnostic-only; regenerate the table from your own
  ROMs with `ver/arm/gen_dbg_golden.py` if you need it. Gameplay is unaffected.
- `mister/eeprom_golden.hex` is a default 93C46 settings image (power-on defaults).
- Absolute build paths were genericized to `/path/to/nightslashers` — adjust to your checkout
  (or use `wsl/build_win_prep.sh`, which rewrites them).

License: GPLv3 (see /LICENSE).
