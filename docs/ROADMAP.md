# Vamphalf: MiSTer core roadmap

**This roadmap is a proposal until the user approves it. No phase executes before that approval,
and a phase whose scope changes goes back for approval.**

## Context

Goal: a DE10-nano MiSTer core for the SemiCom/Sun Hyperstone boards of MAME's
`misc/vamphalf.cpp`, starting with Mission Craft (`misncrft`) and Wivern Wings (`wivernwg`), as one
Quartus 17.0.2 project producing one `.rbf` and a `.mra` per set.

Shape of the work (details and line references in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md)):
the video and I/O are small; the two blocks with no RTL found are the CPU and the sound chip.

1. **Hyperstone E1 CPU** (E1-16 for Mission Craft, E1-32 for Wivern Wings; one core in MAME with a
   bus width difference). From scratch, from `e132xsop.hxx`.
2. **QS1000 voice engine** (32-voice PCM/ADPCM mixer) from `qs1000.cpp`, plus the 8052 from
   `jt8051`, which lacks Timer 2 (not yet known to matter).
3. **Sprite engine**, one layer, 256 sprites per 16-line band: per-scanline, with jotego's
   `jtframe_objdraw` family as the starting point rather than a transcription of MAME's loop.
4. **Protection**: two lookup tables from `vamphalf_prot.cpp`.
5. Glue: 93C46 EEPROM (`jteeprom`), inputs, flip, palette RAM, work RAM, SDRAM backend.

Cross-cutting findings from the earlier cores: [`LESSONS_LEARNED.md`](LESSONS_LEARNED.md). Working
practice: [`WORKFLOW.md`](WORKFLOW.md).

## Progress

**Research done; nothing built.** Repo bootstrapped from the template. `docs/HARDWARE_NOTES.md`
written from the MAME driver. No MAME capture, no RTL.

## Game scope

| Set | Board | CPU / bus | Loaded bytes |
|---|---|---|---|
| misncrft, misncrfta | Sun 2000 | E1-16 (GMS30C2116), 16 | ~9.6 MB |
| wivernwg, wyvernwg, wyvernwga | SemiCom 2001 | E1-32T, 32 | ~19.6 MB |

### Scope decision

- **In scope:** the five sets above. Both boards fit a 32 MB SDRAM module as stored.
- **Out of scope for now:** the other ~40 sets of the driver (YM2151 + OKI boards, Final Godori,
  Boong-Ga Boong-Ga's prize hardware, AOH). They share the video; they add separate sound and I/O.
  Taking them later is Phase 5.
- **First target:** Mission Craft: 16-bit bus, half the GFX, one protection table family.
- **Second target:** Wivern Wings: 32-bit bus, QS1000 with the larger sample ROM, protection at I/O 0x1800.

## Hardware reality

See [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md): chips, clocks, interrupts, memory map, video,
sound, protection, per-game configuration.

### Clocks (proposal)

Pixel clock 7 MHz (28 MHz / 4). Board clocks: CPU 50 MHz, QS1000 24 MHz.
`clk_sys` must be an integer multiple (>= 4x) of 7 MHz and >= 50 MHz: **56 MHz (8x)**. 28 MHz
is 4x but below the CPU clock; 48 MHz is not a multiple of 7 MHz. 56 MHz is above the ~48 MHz
default, and it is forced by those two constraints rather than a measured shortfall. SDRAM on
the same 56 MHz.

| Enable | Ratio from 56 MHz |
|---|---|
| pixel | 1/8, exact |
| CPU 50 MHz | 25/28 fractional enable |
| 8052 oscillator 24 MHz | 3/7 fractional enable |

This is a decision to approve (open item 3).

## Component reuse map

| block | plan | source |
|---|---|---|
| E1-16 / E1-32 CPU | From scratch, from MAME's interpreter | `E:/mame/src/devices/cpu/e132xs/` (BSD-3-Clause) |
| 8052 in QS1000 | Port jt8051, add Timer 2 / 256 B RAM if the firmware needs them | `E:/jtcores/modules/jt8051` (checked for header: README only; licence to be read before vendoring) |
| QS1000 voices | From the software model | `E:/mame/src/devices/sound/qs1000.cpp` |
| Sprite engine | jotego `jtframe_objdraw` / `jtframe_obj_buffer` with board features added | vendored in `Arcade-KonamiGX_MiSTer` |
| EEPROM 93C46 | jteeprom | `E:/jtcores/modules/jteeprom` |
| Protection | Lookup tables, written from the software model | `vamphalf_prot.cpp` |
| OKI / YM2151 | not needed for the first scope | n/a |

jt8051's header licence and the jtframe sprite modules' headers have not been opened yet; the
table says where to look.

## Memory plan (proposal)

Not yet laid out; the sizes are known: Mission Craft GFX 8 MB, Wivern Wings GFX 16 MB, sample ROM
up to 2.5 MB, program 1 MB, 8052 code 128 KB. All in SDRAM (32 MB module). Work RAM 2 MB and
sprite RAM 256 KB are far over BRAM: 2 MB work RAM is SDRAM; sprite RAM (17 bands x 2 KB) and
palette (0x8000 x 16 bit = 64 KB) in BRAM. The CPU's SDRAM latency is the first thing Phase 0
measures. Mapped in `docs/memory_map.md` once Phase 0 gives numbers.

## Design decisions

The template's standing rules apply: follow MAME and log deviations in `docs/MAME_KLUDGES.md`;
approximations in `docs/HACKS.md`; per-scanline sprite rendering; no multiplies in the video path;
one `.rbf` for all sets; two Quartus revisions (`Vamphalf_stp`, `Vamphalf`). Licence per the
template's `LICENSE`.

**Per-scanline sprites, not a frame buffer.** The driver shows a banded list per 16-line strip and
no frame buffer; Phase 1 runs the video-write sweep (in play, 1800 frames or more) to place the
snapshot.

**The CPU is checked by bus trace before anything else.** E1 timing in MAME is described by its
author as probably wrong, so the first measurement is whether bus-trace agreement with MAME is
enough for the attract loop to reach the same frame, not cycle exactness.

## Pitfalls that already bind decisions here

To be filled from `LESSONS_LEARNED.md` when Phase 0 starts (routing table not yet read).

## Phased roadmap

**Phase 0: CPU spike and measurements. The gate.**

1. E1 core written from `e132xsop.hxx`, stood up in `rtl/synth_check/` with the bus wrapper only.
2. The CPU runs the `misncrft` program ROM and matches MAME's bus trace access by access, all
   peripherals stubbed to MAME's values.
3. Measured CPI on game code against 50 MHz, split between execution and SDRAM stall.
4. Standalone Fmax and area at 56 MHz, constraint committed with the measurement.
5. jt8051 runs the QS1000 `u7` firmware to the point where it reads the latch; Timer 2 use
   confirmed or ruled out from the firmware.

**Phase 1: Video against a software model.** `mame_capture.py` plus a `render_model.py`
reproducing `draw_sprites`; write-sweep in play; line engine pixel-identical to MAME on captured
scenes. Exit: `misncrft` frames identical in simulation, flipped and unflipped.

**Phase 2: Hardware bring-up.** SDRAM backend, ROM download, `.mra`, inputs, DIPs, EEPROM, the
standard feature set (CRT Adjust, hiscore, DDR load, HDMI scale/rotate, flip from OSD with the
unflipped-rotated-180 check, Pause input). Exit: Mission Craft boots and plays, silent.

**Phase 3: Sound.** QS1000 voice engine from MAME's model; MAME register-write traces replayed
against it. Exit: audio correct by ear and by captured comparison. MAME's missing envelope and
loop behaviour limit the comparison (HARDWARE_NOTES, Sound).

**Phase 4: Wivern Wings and the clones.** 32-bit bus, protection at 0x1800 and 0x0600, `.mra`
for every set, `MAME_KLUDGES.md` and `HACKS.md` kept current.

**Phase 5: More of the vamphalf driver.** A decision with evidence, per board.

**Phase 6: Savestates and cheats.** Optional. Design for state capture from the first RTL.

## Verification strategy

MAME drives references from scripts; the software model precedes the RTL; vendored modules'
own benches run unchanged on arrival; `.mra` files generated and read back against `ROM_START`.

## Open items

1. **MAME version.** Source tree is a local back-port commit (`a2d0f76268e`); binary is 0.289.
   `-version` against the tree's tag must be checked before any capture is trusted.
2. **E1 timing.** MAME's own comment says its Hyperstone timings are probably incorrect; game
   logic that depends on EEPROM and vblank timing may need correction measured on hardware.
3. **Clock plan.** 56 MHz `clk_sys` (above the ~48 MHz default).
4. **QS1000 accuracy.** MAME implements no envelope, filter or loop; no PCB recording is available.
5. **Protection beyond MAME's tables.** Unseen seeds return 0 in MAME; behaviour of the board
   after ~15 minutes to 2 hours is unverified.
6. **DDR3 / SDRAM size.** Assumed 32 MB SDRAM is enough; the user's memory notes say size for
   128 MB, so more is available.

## Next steps

1. User approval of this roadmap, and answers on open items 1, 3 and the first-target choice.
2. Phase 0 step 1: E1 core.
