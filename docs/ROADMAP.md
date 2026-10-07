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

**Phase 0 under way.** `rtl/e1/e1_cpu.sv` (E1 CPU, multi-cycle, 32-bit bus) matches MAME's
interpreter on 1,000,000 instructions of the `misncrft` boot (76 of 256 opcodes) and on the random
conformance suite (`scripts/e1_regress.py`: 255 of 255 primary opcodes, all DSP extends, delay
slots, user/trace modes, frame/ret spill and fill, vblank interrupts; 0 failures in the seeds run
with 0 and 3 bus wait states). Each run compares PC, SR, 32 globals, 64 locals after every
instruction and every bus access against MAME `-nodrc` traces. Not covered: timer interrupt and TR,
INT1/INT3-IO3, `do`. CPI on the boot trace with a zero-wait bus: 5.24 clk/instruction. Standalone Quartus 17.0.2 fit of the CPU
alone (`scripts/synth_check.py`, 5CSEBA6U23I7, 56 MHz constraint): **8,767 ALMs (21%), 2,871 registers,
7 DSP blocks; Fmax 58.48 MHz** at the slow 100C corner, so it meets 56 MHz. The first version, with
register writes and reads expanded at every call site, needed 196,629 combinational nodes and did not
fit. What changed since: one register write queue (locals commit at the start of the next cycle into an
MLAB register file, globals at its end); operand read in its own state with a one-entry bypass; multiplies
in two registered stages; one exception/interrupt entry state; next-dword instruction prefetch; the next
fetch starts in the cycle the instruction ends and an exception after it only turns the read into a
prefetch. Each timing step was a path from the queue or the commit logic into the fetch address.
E1-32 (Wivern Wings, 32-bit bus): the same RTL matches MAME on 8,000,000 instructions from reset at 0 and 3
wait states (3.53 / 8.40 clk/instruction), including 339 interrupts, the trap table relocated to MEM0 and 18
protection I/O writes (`sim/e1_tb +bus32=1`; traces in `debug/`). The bench substitutes MAME's cycle-count
TR value on `MOV Ln, TR` and forces the timer interrupt from the trace, so the RTL's own timer timing is
unverified (HACKS.md).
**Phase 1 (video) in simulation:** `rtl/video/vh_video.sv` (per-scanline sprite engine, sprite-list snapshot after the
CPU's pass, live palette, 448 x 264 timing at 7 MHz from 56 MHz) renders 38 of 38 steady frames per set pixel-identical
to the software model, which is pixel-identical to MAME on 342 of 342 captured frames per set (`scripts/video_check.py`,
`scripts/render_model.py`, `sim/video_tb`). Worst census frame (96 sprites on a line): 1646-1680 of 3584 clocks for graphics-ROM latencies of
6, 20 and 40 clocks (four requests in flight; `gfx_rdy` lets the memory throttle them). Standalone fit of the block (before the request pipeline): 795 ALMs, 1,304 registers, 266 M10K (48%), Fmax 102 MHz. Sprite RAM
(64 KB) and palette (64 KB) were each stored twice by the fitter (two read ports), since fixed (Phase 3 below). Video sweep: the CPU
rewrites the whole sprite list once per frame on lines 252..259 and the palette on lines 259..263 (`docs/write_timing_mame.txt`).
**Criterion 5 met:** `rtl/qs1000/jt8052` runs the QS1000 firmware `u7` of both sets for 3,000,000
instructions each with 0 mismatches against MAME's 8052 trace (PC, A, B, PSW, SP, DPTR, R0-R7, IE, IP,
timers, port latches, all internal RAM, every external access; 96 and 155 interrupt entries). The unmodified
JT8051 fails at instruction 29: the firmware's stack is at 0xD8, in the 8052's upper RAM. Timer 2 is
unused in the executed and reachable code. Only 12 sound commands per set are covered, no serial port,
no wavetable (`docs/QS1000_8052_FINDINGS.md`). The JT8051 bit-write bug on ACC/B/PSW is worth reporting upstream.
**Phase 2 in simulation:** the board's top level (`Vamphalf.sv`, `rtl/vh_main.sv`, `rtl/vh_cpumem.sv`) runs Mission
Craft from the `.mra` image on the real SDRAM controller and a command-decoding chip model (`sim/sys_tb`). The retired
PCs agree with MAME for all 1,000,000 instructions of the boot trace; the self test reports RAM, EEPROM, SPRITE,
SOUND and MUSIC OK, then shows the SUN logo (frames 59-398 of `debug/sys/m1`). With the idle loop
(no speed-up) it retires about 131,000 instructions a frame at 6.9 clocks each. Two findings: vblank is INT2, not
INT1 (`docs/LESSONS_LEARNED.md`), and the power-on test walks all 256 KB of sprite RAM. `scripts/build_mra.py`
writes the five `.mra` files; each image is identical to the ROM_START image and both sets' graphics region is
identical to MAME's own dump. Speed: the memory path was reworked from `sim/sys_tb +prof` (clocks by memory-unit state
outside the game's idle loop): hits acked in the lookup clock, a D-side next-line prefetch, a four-entry write buffer
and a fetch stash took the busy clocks of 900 attract frames from 357M to 252M; the demo's busiest frame from 92% to 66%
of the frame. With it the core runs a constant 38 frames behind MAME after boot (frames 899 to 2719 checked; 2719-2747
pixel-identical at that offset). Build `5970f0d`: 56 MHz met, +0.897 ns setup slack.
**On the board (`eb2dc6a`, Vamphalf_stp):** Mission Craft runs. The black screen of every earlier build was the E1's
register-write queue: the first of two pushes in one clock never arrived (Quartus and Verilator read
`q[cnt] = v; cnt = cnt + 1` differently), found by the board-against-bench architectural trace
(`rtl/debug/vh_trace.sv`, `scripts/trace_compare.py`; docs/LESSONS_LEARNED.md).
**Phase 3 in simulation:** the QS1000 board (`rtl/qs1000/vh_qs1000.sv`): jt8052 on 3 enables in 7 clocks
(24 MHz), u7 in a 128 KB dual-port block RAM filled from the download, the latch with INT1 and the P3 bit-5
acknowledge, the voice engine (`vh_qs1000_voice.sv`) reading 16-byte sample lines from SDRAM port 1 (double
read). The 8052 with the board's memories and enable (`sim/qs1000_tb -GCORE=2`) matches MAME's trace for
3,000,000 instructions per set, 0 mismatches. The voice engine matches `scripts/qs1000_model.py` sum for sum on
3,000,000 ticks of MAME's register writes per set (`sim/qs1000v_tb`, ROM latency 40-55 clocks). In the whole-board
bench (`sim/sys_tb +wave +mix`, 600 frames), the 8052 writes the same registers in the same order as MAME (1,563
of 1,563 on Mission Craft, 408 of 408 on Wivern Wings, within 142 ticks of MAME's spacing), and the engine's sums
equal the model's replay of those writes on every tick (6.9M and 7.0M ticks, `scripts/qs1000_mix_compare.py`).
The palette and sprite RAMs are now one dual-port array each (`rtl/memory/vh_dpram.sv`).
CPI on the 1,000,000-instruction Mission Craft boot trace: **2.71 clk/instruction with a zero-wait bus,
5.88 with 3 wait states** (it was 5.24, then 7.15 while the Fmax work went in). At 56 MHz that is about
20.7 MIPS zero-wait. Per-state split at zero wait is in the bench output (`+n=...`).

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
| 8052 in QS1000 | `rtl/qs1000/jt8052`: JT8051 with a 256-byte internal RAM address and a fix for bit instructions on ACC/B/PSW; no Timer 2 (neither firmware touches it) | `E:/jtcores/modules/jt8051` at jtcores `5e665515d`; pristine copy and every change in `rtl/qs1000/PROVENANCE.md` |
| QS1000 voices | From the software model | `E:/mame/src/devices/sound/qs1000.cpp` |
| Sprite engine | jotego `jtframe_objdraw` / `jtframe_obj_buffer` with board features added | vendored in `Arcade-KonamiGX_MiSTer` |
| EEPROM 93C46 | jteeprom | `E:/jtcores/modules/jteeprom` |
| Protection | Lookup tables, written from the software model | `vamphalf_prot.cpp` |
| OKI / YM2151 | not needed for the first scope | n/a |

jt8051's header licence and the jtframe sprite modules' headers have not been opened yet; the
table says where to look.

## Memory plan

One 32 MB SDRAM module (the 128 MB one works too), all on `clk_sys`, through `rtl/memory/sdram.sv`
(KonamiGX's controller: burst-4 granules, a double read of 16 bytes). Layout: `rtl/vh_sdram_map.svh`,
which `scripts/build_mra.py` reads.

| What | Where | Why |
|---|---|---|
| Program ROM 1 MB, 8052 code 128 KB, samples 4 MB, graphics 8/16 MB | SDRAM, loaded by the `.mra` | too large for BRAM |
| 8052 code (u7) 128 KB | also BRAM in `vh_qs1000_mcu` (128 M10K), caught on its way to SDRAM | the 8052 reads program and banked data every machine cycle; the firmware uses all 128 KB |
| Work RAM 2 MB | SDRAM `SD_WRAM`, through a 16 KB I-cache and a 4 KB D-cache (16-byte lines, write-through, one-entry write buffer) | too large for BRAM. Cache sizes from `scripts/cpu_mem_model.py` over 150 attract frames of the wivernwg trace: 1.24 I-misses and 69 D-misses per 1000 instructions |
| Sprite RAM above 64 KB (192 KB) | SDRAM `SD_SPRHI`, through the caches | only the power-on test touches it; the video reads bands 1-15 |
| Sprite RAM 64 KB, palette 64 KB | BRAM in `vh_video` | read by the line engine every line |
| E1 internal RAM 4 KB at 0xc0000000 | BRAM in `vh_cpumem` | zero-wait on the chip; about a quarter of Wivern Wings' fetches |
| DDR3 | the HDMI rotator only | no run-time game data |

Ports, fixed priority: 0 the sprite rows (a line deadline), 1 the sound board (Phase 3), 2 the CPU's
line fills and buffered writes, and the ROM download.

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

**Phase 5: More of the vamphalf driver.** The user asked for the other games. MAME's 33 sets (`vamphalf.cpp`
3418-3468; survey of each machine config):

| Group | Sets | New pieces |
|---|---|---|
| a. done | misncrfta, wyvernwga | none (`.mra` only) |
| b. E1-16T, YM2151 + M6295 | coolmini, coolminii, dquizgo2, toyland (coolmini_io); vamphalf, vamphalfr1, vamphalfk (flip bit 7); jmpbreak, jmpbreaka, poosho, newxpang, newxpanga, mrdig (flip at program 0xe0000000 bit 15); solitaire (word-swapped gfx, 11 buttons); mrkicker, dtfamily (OKI bank at I/O 0x000); suplup, luplup, luplup29, luplup10, puzlbang, puzlbanga (14.31818 MHz: 7.159 MHz pixels, YM 3.579545 MHz, sprite colour from word 2's upper byte) | the YM2151 + M6295 board (jt51, jt6295 from jtcores); per-set I/O decode; flip source, palette shift and pixel clock as per-set options |
| c. E1-32T, YM2151 + banked M6295 | finalgdr (32 KB banked backup RAM), mrkickera (MACHINE_NOT_WORKING in MAME) | 32-bit I/O lanes for the sound chips, the backup RAM window, the SemiCom stream values |
| d. protection | worldadv (E1-16T, YM + M6295) | WORLDADV_FPGA_PROT (33-bit serial seed, 7-entry table) |
| e. QS1000 on another map | yorijori (MACHINE_NOT_WORKING: MAME patches a trap at 0x8ff0) | its map, EEPROM wiring and latch lane |
| f. prize hardware | boonggab | 28 MB gfx (past the SDRAM map's 16 MB), 17-bit sprite code, sensor inputs |
| g. a different board | aoh | E1-32XN CPU, its own sprite format and screen, 64 MB gfx |

Order: b first (22 sets on one new sound board), then c and d, then e; f and g only with a memory plan.

**Phase 5 progress.** In the core, each against MAME's trace from reset (`sim/sys_tb +pctrace`, `sim/ref/<set>`):
vamphalf (893,119 instructions, then the YM2151's busy flag is polled a different number of times: MAME_KLUDGES),
coolmini, mrkicker, jmpbreak, mrdig, suplup and worldadv (1,000,000 of 1,000,000 each); their clones and siblings share
the families (vamphalfr1, vamphalfk, coolminii, dquizgo2, toyland, dtfamily, jmpbreaka, poosho, newxpang, newxpanga,
luplup, luplup29, luplup10, puzlbang, puzlbanga). 27 sets with misncrft and wivernwg's five. The YM2151 + M6295 board
against MAME's audio: correlation 0.971, RMS ratio 1.008 (vamphalf). World Adventure's protection replays MAME's seven
checks of a 2-hour run, 0 differ. Not done: video frames against MAME per set (the engine is the one checked on misncrft
and wivernwg; suplup's colour shift is new and unchecked), solitaire (an 11-button panel: its own joystick layout and
keys), finalgdr and mrkickera (32 KB banked backup RAM, 32 more M10K, and its .nvm; mrkickera MACHINE_NOT_WORKING),
yorijori (MACHINE_NOT_WORKING), boonggab and aoh (groups f and g).

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
