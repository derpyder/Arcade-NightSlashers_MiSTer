# Night Slashers for MiSTer

**Night Slashers** (Data East, 1994) — the horror beat 'em up — running natively on MiSTer FPGA.
First FPGA implementation of the Data East **deco32** hardware: encrypted ARM6 main CPU (DE 156),
dual DECO 52/153 sprite generators, four playfields, and the "Ace" (chip 99) colour blender.

## Status — v1.0

Fully playable, hardware-verified on DE10-Nano:

- Encrypted ARM6 (DE 156) main CPU with on-the-fly decryption
- Two sprite chips (5bpp + 4bpp) with per-pixel priority mixing
- Ace palette engine: scene fades, **variable-alpha blending** — stage-2 mist/fog,
  transparent carriage sprites, character shadows
- Joint-8bpp playfield mode (the full-colour character bios / story-art portraits)
- Per-tile playfield flip, tile banking
- Z80 + YM2151 + dual OKI M6295 sound
- 93C46 EEPROM settings + service menu, 3-player inputs

## Install

1. Copy `releases/jtnslasher_*.rbf` to `/media/fat/_Arcade/cores/`
2. Copy the `.mra` files to `/media/fat/_Arcade/`
3. ROMs (MAME set 0.284: `nslasher` / `nslasherj` / `nslashers`) go in `/media/fat/games/mame/`

Region notes: **Over Sea** (World, ver 1.2) and **Korea** (ver 1.3, parent); the **Japan** set
(ver 1.2) has the uncensored gore hardwired.

> Do not regenerate these MRAs with stock tooling — they encode this core's custom SDRAM layout.

## Credits & license

- Built on **[JTFRAME](https://github.com/jotego/jtframe)** by Jose Tejada (jotego) — thank you.
- Sound: jt51 (YM2151) and jt6295 (OKI) by jotego. ARM CPU derived from the Amber project (OpenCores).
- Reference: MAME 0.284 `deco32` driver.
- Port by **rejectedcoins**.

License: **GPLv3**. This repository currently distributes binary releases and the arcade ROM
mapping files; the full source tree will be published here after the remaining Data East family
cores built on it are completed.

*This core is for use with legally obtained ROMs only.*
