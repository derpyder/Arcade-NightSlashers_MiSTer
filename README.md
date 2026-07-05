# Night Slashers for MiSTer

**Night Slashers** (Data East, 1994) — the horror beat 'em up — running natively on MiSTer FPGA.
First FPGA implementation of the Data East **deco32** hardware: encrypted ARM6 main CPU (DE 156),
dual DECO 52/153 sprite generators, four playfields, and the "Ace" (chip 99) colour blender.

## v1.1 — Sound update (2026-07-04)

- **Rebalanced audio mix** — music (YM2151) brought down, voice (OKI1 speech) up, SFX (OKI2)
  adjusted, after diffing each channel against MAME. Addresses the "imbalanced music / missing
  voice" reports.
- **EEPROM ships blank** — each set now self-configures its own region defaults on first boot
  (a single preloaded region image had previously forced Over Sea settings onto every set).
- **Over Sea MRA** main-CPU CRCs corrected.

> **Gore is off by default** on every version — including the Japan set — matching the original
> PCB. Turn it on in the service menu (see *Enabling gore* below).

One rbf serves all three MRAs.

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

Region notes: three sets share one rbf — **Japan** (ver 1.2), **Korea** (ver 1.3, parent), and
**Over Sea** (World, ver 1.2). The EEPROM ships blank, so each writes its own region defaults on
first boot.

### Enabling gore

Violence/gore is **off by default on every version** (as on the original PCB) — the Japan set
included. To turn it on:

1. Open the **service menu** — flip **Service mode** on in the core's OSD (or hold the Test switch),
   then reset into the menu.
2. Find the **gore / violence** option and set it **on**.
3. Exit the service menu to save, and toggle Service mode back off.

Because the EEPROM ships blank, this is an operator setting you enable once in the menu; if it ever
resets, just repeat the steps.

> Do not regenerate these MRAs with stock tooling — they encode this core's custom SDRAM layout.

## Credits & license

- Built on **[JTFRAME](https://github.com/jotego/jtframe)** by Jose Tejada (jotego) — thank you.
- Sound: jt51 (YM2151) and jt6295 (OKI) by jotego. ARM CPU derived from the Amber project (OpenCores).
- Reference: MAME 0.284 `deco32` driver.
- Port by **[rejectedcoins](https://rejectedcoins.com)**.

License: **GPLv3** (see [LICENSE](LICENSE)). Core source is in [`source/`](source/) — a drop-in
tree for [jtcores](https://github.com/jotego/jtcores); build notes in
[`source/SOURCE.md`](source/SOURCE.md). Simulation golden data is regenerated from your own ROMs
(none is distributed).

*This core is for use with legally obtained ROMs only.*
