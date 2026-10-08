# Vamphalf core for MiSTer

A MiSTer FPGA core for the Hyperstone E1-based arcade boards of MAME's `vamphalf` driver (Danbi /
F2 System, SemiCom, Sun, Omega System, Logic), built with Quartus Prime 17.0.2 Lite for the DE10-nano.

**Status: work in progress. All 27 sets run and play on the board; some lose a small number of frames
that do not complete in time.**

## Contents

- [History](#history)
- [Games](#games)
  - [Supported](#supported)
  - [Not yet](#not-yet)
  - [Out of scope for now](#out-of-scope-for-now)
- [Hardware](#hardware)
  - [Video timing](#video-timing)
- [Installation](#installation)
- [Controls](#controls)
- [Status](#status)
  - [Features](#features)
  - [Todo](#todo)
  - [Resource usage](#resource-usage)
- [AI Attestation](#ai-attestation)
- [Verification](#verification)
- [Acknowledgements](#acknowledgements)
- [Layout](#layout)
- [License](#license)

## History

* **20261008** (`releases/Arcade-Vamphalf_20261008.rbf`)
  * Initial release
  * Fixes relative sound volume of the QS1000 versus YM2151 / OKI M6295 compared to MAME based on PCB recording
  * A few games suffer a little slowdown/dropped frames, will continue to work on it
  * Fast rom loading
  * CRT Adjust
  * HDMI Flipscreen/rotation
  * MAME Arcade keyboard mapping

## Games

The supported sets run on three boards: the E1-16 (GMS30C2116 / E1-16T) board with a QS1000 sound board
(Mission Craft), the E1-32 board with a QS1000 (Wivern Wings), and the E1-16 board with a YM2151 and an
OKI M6295 (the other 22 sets, in six I/O map families). All three have the same video: one layer of
16x16 sprites from a list in sprite RAM, and a 15-bit palette. A 32 MB SDRAM module holds every set (the
largest image is 24 MB; work RAM sits above it).

### Supported

| Name | Year | Manufacturer | Set | Board | MAME trace | Notes |
|-|-|-|-|-|-|-|
| Mission Craft (version 2.7) | 2000 | Sun | `misncrft` | E1-16, QS1000 | 1,000,000 of 1,000,000 | |
| Mission Craft (version 2.4) | 2000 | Sun | `misncrfta` | E1-16, QS1000 | | Clone of `misncrft` |
| Wivern Wings | 2001 | SemiCom | `wivernwg` | E1-32, QS1000 | 8,000,000 (CPU bench) | |
| Wyvern Wings (set 1) | 2001 | SemiCom (Game Vision license) | `wyvernwg` | E1-32, QS1000 | | Clone of `wivernwg` |
| Wyvern Wings (set 2) | 2001 | SemiCom (Game Vision license) | `wyvernwga` | E1-32, QS1000 | | Clone of `wivernwg` |
| Vamf x1/2 (Europe, version 1.1.0908) | 1999 | Danbi / F2 System | `vamphalf` | E1-16, YM2151 + M6295 | 893,119, then the YM2151's busy flag is polled a different number of times | |
| Vamf x1/2 (Europe, version 1.0.0903) | 1999 | Danbi / F2 System | `vamphalfr1` | E1-16, YM2151 + M6295 | | Clone of `vamphalf` |
| Vamp x1/2 (Korea, version 1.1.0908) | 1999 | Danbi / F2 System | `vamphalfk` | E1-16, YM2151 + M6295 | | Clone of `vamphalf` |
| Cool Minigame Collection | 1999 | SemiCom | `coolmini` | E1-16, YM2151 + M6295 | 1,000,000 of 1,000,000 | |
| Cool Minigame Collection (Italy) | 1999 | SemiCom | `coolminii` | E1-16, YM2151 + M6295 | | Clone of `coolmini` |
| Date Quiz Go Go Episode 2 | 2000 | SemiCom | `dquizgo2` | E1-16, YM2151 + M6295 | | coolmini's board |
| Toy Land Adventure | 2001 | SemiCom | `toyland` | E1-16, YM2151 + M6295 | | coolmini's board |
| Mr. Kicker (F-E1-16-010 PCB) | 2001 | SemiCom | `mrkicker` | E1-16, YM2151 + M6295 | 1,000,000 of 1,000,000 | |
| Diet Family | 2001 | SemiCom | `dtfamily` | E1-16, YM2151 + M6295 | | mrkicker's board |
| Jumping Break (set 1) | 1999 | F2 System | `jmpbreak` | E1-16, YM2151 + M6295 | 1,000,000 of 1,000,000 | |
| Jumping Break (set 2) | 1999 | F2 System | `jmpbreaka` | E1-16, YM2151 + M6295 | | Clone of `jmpbreak` |
| Poosho Poosho | 1999 | F2 System | `poosho` | E1-16, YM2151 + M6295 | | jmpbreak's board |
| New Cross Pang (set 1) | 1999 | F2 System | `newxpang` | E1-16, YM2151 + M6295 | | mrdig's board |
| New Cross Pang (set 2) | 1999 | F2 System | `newxpanga` | E1-16, YM2151 + M6295 | | Clone of `newxpang` (jmpbreak's board) |
| Mr. Dig | 2000 | Sun | `mrdig` | E1-16, YM2151 + M6295 | 1,000,000 of 1,000,000 | |
| Super Lup Lup Puzzle / Zhuan Zhuan Puzzle (version 4.0 / 990518) | 1999 | Omega System | `suplup` | E1-16, YM2151 + M6295 | 1,000,000 of 1,000,000 | Runs 2.2% slow (pixel clock) |
| Lup Lup Puzzle / Zhuan Zhuan Puzzle (version 3.0 / 990128) | 1999 | Omega System | `luplup` | E1-16, YM2151 + M6295 | | Clone of `suplup` |
| Lup Lup Puzzle / Zhuan Zhuan Puzzle (version 2.9 / 990108) | 1999 | Omega System | `luplup29` | E1-16, YM2151 + M6295 | | Clone of `suplup` |
| Lup Lup Puzzle / Zhuan Zhuan Puzzle (version 1.05 / 981214) | 1999 | Omega System (Adko license) | `luplup10` | E1-16, YM2151 + M6295 | | Clone of `suplup` |
| Puzzle Bang Bang (Korea, version 2.9 / 990108) | 1999 | Omega System | `puzlbang` | E1-16, YM2151 + M6295 | | Clone of `suplup` |
| Puzzle Bang Bang (Korea, version 2.8 / 990106) | 1999 | Omega System | `puzlbanga` | E1-16, YM2151 + M6295 | | Clone of `suplup` |
| World Adventure | 1999 | Logic / F2 System | `worldadv` | E1-16, YM2151 + M6295 | 1,000,000 of 1,000,000 | Protection: MAME's seven checks replayed, 0 differ |

### Not yet

| Name | Why |
|-|-|
| Solitaire (version 2.5) | An 11-button panel: its own joystick layout and keyboard map |
| Final Godori (Korea, version 2.20.5915) | E1-32 with the YM2151 + M6295, and a 32 KB banked backup RAM with its `.nvm` |
| Boong-Ga Boong-Ga (Spank'em!) | 28 MB of graphics, past the core's 16 MB graphics space; a 17-bit sprite code; sensor inputs |
| Age Of Heroes - Silkroad 2 | An E1-32XN CPU at 80 MHz, its own sprite format and screen, 64 MB of graphics |

### Out of scope for now

| MAME description | Why |
|-|-|
| Mr. Kicker (SEMICOM-003b PCB) | MACHINE_NOT_WORKING in MAME (the set corrupts its EEPROM) |
| Yori Jori Kuk Kuk | MACHINE_NOT_WORKING in MAME (MAME patches the program to boot) |

## Hardware

| Chip | Function | Status |
|-|-|-|
| Hyperstone E1-16T / GMS30C2116, E1-32T, 50 MHz | Main CPU | Written here (`rtl/e1/e1_cpu.sv`) from MAME's `e132xs`, multi-cycle, behind a 16 KB I-cache and a 4 KB D-cache (`rtl/vh_cpumem.sv`) |
| Sprites and palette | Video | Written here (`rtl/video/vh_video.sv`): rendered per scanline from a copy of the sprite list taken once a frame |
| QS1000 (8052 + 32-voice wavetable) | Sound, QS1000 boards | 8052: jotego's JT8051, changed (`rtl/qs1000/PROVENANCE.md`); wavetable written here from MAME's `qs1000.cpp` (`rtl/qs1000/vh_qs1000_voice.sv`) |
| YM2151 | FM sound | jotego's JT51 (`rtl/sound/PROVENANCE.md`) |
| OKI M6295 | ADPCM sound | jotego's JT6295, with the Fuuki core's ROM bridge and sample cache |
| 93C46 | Settings EEPROM | From Arcade-KonamiGX_MiSTer |
| Protection | Mission Craft, Wivern Wings, World Adventure | MAME's tables (`vamphalf_prot.cpp`): `rtl/vh_prot.sv`, `rtl/vh_prot_wa.sv` |

### Video timing

28 MHz / 4 = 7 MHz dot clock, 448 dots by 264 lines: 15.625 kHz lines, 59.19 Hz frames. Visible 320 x 236
(dots 31 to 350, lines 16 to 251). Source: MAME's `set_raw` (`vamphalf.cpp:156-161`, `:1150`). The SUPLUP
board's dot clock is 14.318181 MHz / 2 = 7.159 MHz (60.53 Hz, `:1251`); the core runs it at 7 MHz
(`docs/HACKS.md`).

## Installation

A 32 MB SDRAM module is required.

* Take the latest `*.rbf` from `releases/` and put it in `_Arcade/cores`, renamed to drop the
  `Arcade-` prefix (`Arcade-Vamphalf_YYYYMMDD.rbf` becomes `Vamphalf_YYYYMMDD.rbf`)
* Put the `*.mra` files and the `_alternatives` folder from `releases/` in `_Arcade` (or a subdirectory
  starting with an underscore, e.g. `_Arcade/_Vamphalf`)
* Put the MAME merged or split ROM sets in `games/mame`

To build and deploy a development build: `python scripts/build_staged.py`, then `python scripts/deploy.py`
with a `mister.env` (see `scripts/deploy.py`).

## Controls

Pad: Button 1-4, Start, Coin, Pause, Service (the `.mra` names Wivern Wings' Shot, Defense and Bomb).
Pause suspends the main CPU. MAME gives the boards no DIP switches; F2, or the OSD's Service Mode, is the
service switch.

Keyboard, MAME's defaults: arrows / R F D G, buttons LCtrl LAlt Space LShift / A S Q W, Start 1 / 2,
Coin 5 / 6; F2 service switch, 9 service coin, P pause.

## Status

Known issues:

* **The CPU is slower than the original**: some games lose a small number of frames that do not
  complete in time. On the bench (900 frames, coin then play, after commit `ff38ff1`), frames in which
  the game never reached its idle loop: New Cross Pang 30, Toy Land 10, Jumping Break 3, Mission Craft 0.
  The other sets have not been measured since that change.
* The QS1000 follows MAME's model, which has no envelopes, filter or looping. Its balance of ADPCM against
  PCM voices is taken from a recording of a Mission Craft PCB instead of MAME's (effects 18 dB higher
  against the music, `docs/MAME_KLUDGES.md`).
* The SUPLUP board's games run 2.2% slow (pixel clock).
* Not yet checked on the board: flip screen, the `.nvm` save and restore.

`docs/MAME_KLUDGES.md` lists what is taken from MAME as behaviour and what is known not to be
right. `docs/HACKS.md` lists this core's own approximations. `docs/ROADMAP.md` is the plan and its
progress.

### Todo

- [ ] CPU speed (`docs/ROADMAP.md`, CPU throughput)
- [ ] Video frames against MAME for the sets other than Mission Craft and Wivern Wings
- [ ] Flip screen and `.nvm` on the board
- [ ] Solitaire, Final Godori

### Resource usage

The release revision (`Vamphalf`, commit `eaa95df`, seed 7) on the DE10-nano's Cyclone V 5CSEBA6, speed
grade 7, every clock meeting timing (clk_sys +0.764 ns):

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 29,501 | 41,910 |
| Block memory bits | 3,046,765 | 5,662,720 |
| RAM blocks | 425 | 553 |
| DSP blocks | 47 | 112 |
| PLLs | 3 | 6 |

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant.

MAME's `vamphalf.cpp`, `vamphalf_prot.cpp`, `qs1000.cpp` and `e132xs` are the reference. Where the core
follows MAME on something MAME marks as uncertain, it is listed in `docs/MAME_KLUDGES.md`; the core's own
approximations are in `docs/HACKS.md`. The one place the core departs from MAME on purpose, the QS1000's
mix balance, is taken from a PCB recording of Mission Craft (https://www.youtube.com/watch?v=ur5dur6w9L4).
What has been checked is listed under Verification.

## Verification

Not PCB-validated. MAME is the accuracy reference.

* CPU: `rtl/e1/e1_cpu.sv` agrees with MAME's interpreter after every instruction (PC, SR, all registers,
  every bus access), at 0 and 3 bus wait states, on Mission Craft's first 1,000,000 instructions, Wivern
  Wings' first 8,000,000 (E1-32) and the random conformance suite (`scripts/e1_regress.py`, 255 of 255
  primary opcodes).
* Whole board (`sim/sys_tb`, the SDRAM controller and a chip model) against MAME's trace from reset:
  1,000,000 of 1,000,000 instructions on `misncrft`, `coolmini`, `mrkicker`, `jmpbreak`, `mrdig`,
  `suplup` and `worldadv`; 893,119 on `vamphalf`.
* Video: the line engine renders 38 of 38 frames per set pixel-identical to a model of MAME's
  `draw_sprites`, which is pixel-identical to MAME on 342 of 342 captured frames of `misncrft` and of
  `wivernwg`.
* `.mra`: every set's image is identical to MAME's ROM_START image (`scripts/build_mra.py`).
* ROM loading (`sim/top_tb`): the byte path and the fast load both leave SDRAM, the QS1000's u7 and the
  EEPROM identical to the image (or to a `.nvm` loaded after it).
* QS1000: the 8052 with the board's memories agrees with MAME's trace for 3,000,000 instructions per set
  (`sim/qs1000_tb`); the wavetable engine equals a transcription of MAME's on every tick, 3,000,000 per
  set alone (`sim/qs1000v_tb`) and 6.9M and 7.0M in the whole board in play, where the 8052's register
  writes equal MAME's.
* YM2151 + M6295 against MAME's audio of `vamphalf`: correlation 0.971, RMS ratio 1.008.
* Protection: Mission Craft's power-on check, 90 of 90 accesses as MAME; World Adventure's seven checks of
  a 2-hour MAME run, 0 differences.

## Acknowledgements

- **Sorgelig** and the **MiSTer-devel team** for the
  [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) framework, and Sorgelig's
  `sdram.v`, here by way of the Psikyo, Fuuki and KonamiGX cores.
- The **MAMEdev team**: Angelo Salese, David Haywood, Pierpaolo Prazzoli and Tomasz Slanina
  (`vamphalf.cpp`), Philip Bennett (`qs1000.cpp`), Pierpaolo Prazzoli (`e132xs`), for the driver and
  device emulations that are this core's specification.
- **Jose Tejada (jotego)** for JT8051, JT51 and JT6295 ([jtcores](https://github.com/jotego/jtcores)).
- **Umberto Parisi (rmonic79)** for `crt_adjust.sv`, from Arcade-Raiden_MiSTer by way of the Fuuki core.

## Layout

Standard [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) structure:

| path | contents |
| - | - |
| `sys` | MiSTer framework, vendored from the template, never edited |
| `rtl` | core source; vendored modules carry a `PROVENANCE.md` |
| `releases` | `.rbf` and `.mra` files; clones in `_alternatives` |
| `docs` | roadmap, workflow, release process, kludges, hacks, lessons |
| `sim` | ModelSim and Verilator testbenches |
| `scripts` | build, deploy, capture and verification tooling |
| `debug` | reference captures from MAME used as ground truth (gitignored) |
| `roms` | your own MAME sets (gitignored, never committed) |

## License

GPL-3.0 (see `LICENSE`). Imported components keep their own licences; the `PROVENANCE.md` file beside
each vendored directory has the detail.

Game ROMs contain copyrighted material and are not included. Obtaining them is your
responsibility.
