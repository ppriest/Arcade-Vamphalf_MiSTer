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

One 32 MB SDRAM module, and the 128 MB module for boonggab alone (the user's choice: its graphics from 16 MB up
at `SD_GFXHI`, above the 32 MB line), all on `clk_sys`, through `rtl/memory/sdram.sv`
(KonamiGX's controller: burst-4 granules, a double read of 16 bytes). Layout: `rtl/vh_sdram_map.svh`,
which `scripts/build_mra.py` reads.

| What | Where | Why |
|---|---|---|
| Program ROM 1 MB (yorijori 2 MB), 8052 code 128 KB, samples 4 MB, graphics 8/16 MB (boonggab 28 MB) | SDRAM, loaded by the `.mra` | too large for BRAM |
| 8052 code (u7) 128 KB | also BRAM in `vh_qs1000_mcu` (128 M10K), caught on its way to SDRAM | the 8052 reads program and banked data every machine cycle; the firmware uses all 128 KB |
| Work RAM 2 MB | SDRAM `SD_WRAM`, through a 16 KB I-cache and a 4 KB D-cache (16-byte lines, write-through, one-entry write buffer) | too large for BRAM. Cache sizes from `scripts/cpu_mem_model.py` over 150 attract frames of the wivernwg trace: 1.24 I-misses and 69 D-misses per 1000 instructions |
| Sprite RAM above 64 KB (192 KB) | SDRAM `SD_SPRHI`, through the caches | only the power-on test touches it; the video reads bands 1-15 |
| Sprite RAM 64 KB, palette 64 KB | BRAM in `vh_video` | read by the line engine every line |
| E1 internal RAM 4 KB at 0xc0000000 | BRAM in `vh_cpumem` | zero-wait on the chip; about a quarter of Wivern Wings' fetches |
| DDR3 | the HDMI rotator; the ROM image at load time (fast load: `rtl/memory/vh_rom_loader.sv` copies it to SDRAM with the game in reset) | no run-time game data |
| DDR3, `Limenko` revision | the sprite frame buffer during play: two 384 x 240 x 16-bit frames, drawn over one frame, swapped at the interrupt (Phase 8) | the board's own double-buffered frame (two IS41C16256); two frames in BRAM need 252 M10K or more with about 170 free; on SDRAM the up to 258,624 single-word writes a frame exceed the frame. The user's choice over a per-line renderer |

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
coolmini, mrkicker, mrkickera, jmpbreak, mrdig, suplup, worldadv, boonggab, finalgdr and aoh (1,000,000 of 1,000,000 each),
solitaire (869,671, then a YM2151 status read differs, as vamphalf's); their clones and siblings share the families (vamphalfr1, vamphalfk, coolminii, dquizgo2, toyland, dtfamily, jmpbreaka, poosho,
newxpang, newxpanga, luplup, luplup29, luplup10, puzlbang, puzlbanga). 31 sets with misncrft and wivernwg's five. The YM2151 + M6295 board
against MAME's audio: correlation 0.971, RMS ratio 1.008 (vamphalf). World Adventure's protection replays MAME's seven
checks of a 2-hour run, 0 differ. Not done: video frames against MAME per set (the engine is the one checked on misncrft
and wivernwg; suplup's colour shift is new and unchecked). aoh (group g): its own video mode, checked frame by frame
(render_model.py equals MAME on 6 of 6 frames, the RTL equals the model on 6 of 6, flip equals the unflipped frame
turned 180 degrees on 5 of 5). It plays on the board (the user), with occasional tearing when the screen scrolls
vertically, from the CPU's speed. In MAME its CPU is busy for a median 0.068 of
an 80 MHz frame, 0.224 at the 99th percentile (scripts/mame_busy.py). yorijori agrees with MAME (SETADR fix, no ROM patch) for 439,730 instructions, then the timer
interrupt's timing differs; it plays on the board (the user).

**CPU throughput** (`ff38ff1`, asked for by the user after Phase 5). `sim/sys_tb +prof` split the busy clocks by
CPU state: in the slow sets stores waited for the write buffer 20-26% of the time (a 32-bit store was two SDRAM
writes) and extension words and fetch waits took 20%. Changes: an instruction port of its own (8 bytes per fetch,
read-ahead independent of loads and stores), extension words taken in ST_RD, SDRAM burst writes of up to 8 bytes,
and a write buffer that merges stores into the newest 8-byte entry. Bench, 1000 frames, coin at 300, play from 600
(`debug/speed/<set>_prof*.txt`):

| set | clk/instruction before → after | frames that never reached the idle loop, before → after |
|---|---|---|
| misncrft | 4.69 → 3.73 | 0 → 0 |
| newxpang | 5.54 → 3.39 | 113 → 30 |
| jmpbreak | 4.93 → 3.58 | 81 → 3 |
| toyland | 5.29 → 3.78 | 59 → 10 |

What is left, by the same profile: data reads (D-cache misses are 15-18% of busy clocks; misses per instruction
barely fall with cache size and halve with line size, `scripts/cpu_mem_model.py`, so they are streaming reads) and
the two clocks every instruction spends in ST_RD and ST_EXEC.

Writes acked in their request clock and the timer's TCR match taken a clock later (`dbdb9ec`), 1300 frames:
busy clocks -3.0% (newxpang), -4.2% (toyland), -5.6% (jmpbreak); frames that never reached the idle loop
43 -> 39, 10 -> 8, 4 -> 3. A 16 KB D-cache cut busy clocks 1-2% and was not kept. In play (newxpang) ST_RD is
27% and ST_EXEC 24% of busy clocks; a fast path skipping ST_RD after a one-clock instruction applies to 22% of
instructions (a MAME trace of 30 frames of play), about 5% of busy clocks. Larger gains need a pipeline.

**Phase 6: Savestates and cheats.** Optional. Design for state capture from the first RTL.

**Phase 7: A pipelined E1.** Asked for by the user, for this core's heavy frames (New Cross Pang, Toy Land, Age
Of Heroes' tearing) and for the Eolith core, which runs the same CPU. Goal: two clocks an instruction or fewer
in play at 56 MHz, from 3.5-4.4 now. Approved by the user; under way.

- `rtl/e1/e1_pipe.sv` beside `e1_cpu.sv`, which stays as the reference and the fallback (one of the two in a build).
- Stages: fetch (8-byte blocks into an instruction queue, lengths predecoded); decode and register read (the
  window index from the frame pointer of the instruction being decoded; operands forwarded from execute and
  memory); execute (ALU, flags, branch resolution, effective address); memory (the D-cache; a hit returns in
  this stage); write-back (register file, SR).
- Hazards: registers and flags forwarded; a stall on load-use; frame-pointer changes (FRAME, CALL, RET, writes to
  SR) and delayed branches drain the pipe; traps and interrupts at instruction boundaries.
- A slow path for what the pipe does not take at first (MUL/DIV, the DSP extensions, the frame spill and fill
  loops, LDD/STD, traps): the pipe drains and the instruction runs as `e1_cpu.sv` runs it.
- `vh_cpumem`: a hit in one clock from an address registered in execute; 32-byte lines for the streaming reads
  (misses per instruction halve with line size, `scripts/cpu_mem_model.py`).
- Verification before hardware: the conformance suite (52 seeds, 255 primary opcodes, 0 and 3 wait states,
  `scripts/e1_regress.py`) and every set's MAME trace (`sim/sys_tb +pctrace`); timing at 56 MHz; then the speed
  survey and probe S on the board.
- Steps, each verified before the next: (1) the pipe for ALU and immediate instructions, everything else on the
  slow path; (2) loads and stores; (3) branches, delayed ones included; (4) the memory side; (5) hardware.
- Risks: timing closure with forwarding on the execute path (+1.2 ns of slack today without the timer chain);
  every MAME quirk marked "MAME:" in `e1_cpu.sv` has to carry over.

Status: steps 1-4 in simulation, built in with `E1_PIPE` (`files.qip`). As built, `e1_pipe.sv` keeps e1_cpu's
execute and its multi-clock states whole and puts fetch (F, a whole instruction a clock into D) and operand read
(R, every clock) ahead of it; the next instruction goes into execute beside the last clock of an ALU instruction,
a load or store (LDD's two results included), or a BR going as predicted (F predicts BR taken), and R takes that
clock's writes into the operands it reads, so execute reads only registers. `vh_cpumem`: a miss no longer waits
for an unrelated write buffer, waits for the line's prefetch when it is in flight, and a load announced in
execute (`la_req`) hits in one clock; a two-access job issues its second access as the first is acked.
Conformance 104 of 104 runs; MAME PC traces as `e1_cpu` on all 14 sets (three differ from MAME at the same
instruction with either CPU). Release builds, seed 3: `4f1ed2e` +0.778 ns, `5dab2e1` +0.053 ns at `clk_sys`, 467 of
553 RAM blocks (seed 1 of `4f1ed2e` missed the HDMI clock by 11 ps); `5c4af03` +0.649 ns, 34,988 ALMs; `8f1f21c` +1.708 ns, 32,580 ALMs (the register-write queue and operand forwarding changes from Arcade-Eolith_MiSTer, where its LESSONS_LEARNED, Timing closure, `[Eolith]`, has the mechanism; every check above unchanged). In play (`sim/sys_tb
+prof`, 1300 frames, coin at 300), clocks per instruction while busy:

| | e1_cpu | step 1 | 2 | 3 | 4 | `5dab2e1` | frames without idle, e1_cpu -> `5dab2e1` |
|---|---|---|---|---|---|---|---|
| New Cross Pang | 4.23 | 3.74 | 3.53 | 3.35 | 3.10 | 2.83 | 39 -> 3 |
| Toy Land | 4.04 | 3.64 | 3.39 | 3.27 | 2.97 | 2.64 | 8 -> 4 |
| Jumping Break | 3.44 | 2.93 | 2.68 | 2.57 | 2.41 | 2.23 | 3 -> 0 |

What is left is memory. Every set measured copies 32 KB of work RAM to sprite RAM a frame from internal RAM
(`0xc0000006`, LDD.P/STD.P), 16-28% of busy clocks, and reads it once a frame in order: a 16 KB D-cache would catch
8% of those misses, 32 KB 25% (`+misslog`, New Cross Pang). Line fills are 22% of New Cross Pang's busy clocks at
13 clocks each, about 7 of them waiting for port 2. Tried and dropped: looking up LDD's second access during its
first (the clock moved into waiting for the prefetch), two prefetch buffers (demand misses waited behind them:
slower on all three sets). Next: step 5 on the board (the probe revision needs timing: -0.222 ns at `700d599`);
faster port-2 fills would need `sdram.sv`.

**Phase 8: Limenko Power System 2, a second `.rbf`.** Asked for by the user. MAME `limenko.cpp` (`96962b96c89`):
Dynamite Bomber (`dynabomb`), Legend of Heroes (`legendoh`), Super Bubble 2003 (`sb2003`, `sb2003a`), To Heart House
(`hrthouse`, `MACHINE_IMPERFECT_GRAPHICS`) and Spotty (`spotty`, Prince Co., "only uses the same graphics chip"). The five
parent sets are in `roms/`. Approved by the user with all five in scope. Step 1 done (below); the user chose the
DDR3 frame buffer.

- Shared with this core: the E1-32XN at 80 MHz (20 MHz x 4, as `aoh`), `e1_pipe` and `vh_cpumem`; the QS1000 (24 MHz,
  the 8052 with its P3-banked data window, the voice engine); the 93C46 EEPROM; the vblank interrupt
  (`irq0_line_hold`). Spotty has instead an AT89C4051 (an 8051, 4 MHz) driving one M6295: jt8052 and jt6295 are in the
  core.
- Different: the memory map (main RAM 2 MB at 0, program ROM 2 MB at 0xffe00000, data ROM 4 MB at 0x40000000; at
  0x80000000 three tilemap RAMs of 32 KB, sprite RAM 8 KB in two banks, palette 8 KB of xBGR555, video registers at
  0x8001ffec, the sprite-draw command at 0x8003e000), the I/O map (inputs at 0x0000, 0x0200, 0x0400 in bits 31:16, the
  EEPROM at 0x1200, the sound latch at 0x1400 bits 23:16) and the video chip (`SYS L2D_HYP`).
- Video: three 8x8 8bpp tilemaps (128 x 64 tiles, x and y scroll and an enable per layer from the video registers;
  bg opaque, md and fg with pen 0 transparent) and bitmap sprites (8 to 64 pixels wide and high in steps of 8, 8bpp,
  flip x and y, the code a byte offset / 64 into the graphics ROM, two priorities: below fg or above all), up to 1024 a
  frame. A CPU write to 0x8003e000 swaps the sprite-RAM banks and draws the bank now selected into a 512 x 512 frame,
  shown until the next command. The main board has two 256K x 16 DRAMs (IS41C16256, 512 KB each, one 512 x 512 x
  16-bit frame) beside the video chip: hardware evidence for a double-buffered sprite frame buffer.
- Step 1 (`docs/lm_census_mame.txt`, `docs/write_timing_mame.txt`; attract and play, 1800 frames each, all six sets):
  one draw command in every frame, on line 0 after the interrupt, then the sprite list, registers, palette and VRAM
  written by line 106 at the latest (dynabomb attract; 72 or earlier in the others). Worst line 1536 bytes of sprite
  rows (sb2003); most sprites on a line 59 (sb2003 play); worst command 266 sprites, 258,624 pixels drawn. Five sets
  rewrite the bank MAME has just drawn from line 0..8 after the command, so either design copies the list (1026
  dwords at the largest count seen, hrthouse's 512) before the first such write.
- Sprite buffer options (the user chose DDR3; memory plan), M10K counts estimated from the Vamphalf fit's per-module figures (about 385 of 553 used
  without sprite buffering, the three tilemap RAMs 96 of them):
  - Per line, from the list copied at the command (MAME's picture: one list per frame, drawn whole). About 10 M10K.
    Worst line: 1536 bytes of sprite rows plus 1152 of tile rows from SDRAM, an estimated 2500-3000 of 3584 clocks
    from `sdram.sv`'s state counts (not measured); the CPU gets the rest.
  - Frame buffer in BRAM: two 384 x 240 x 13-bit frames need 252 M10K or more; about 170 are free. Does not fit.
  - Frame buffer in SDRAM: up to 258,624 single-word writes a frame at about 8 clocks each on `sdram.sv` exceeds
    the 946,000-clock frame. Does not fit without a burst-write controller.
  - Frame buffer in DDR3 (the board's structure, drawn over the frame): the sprite rows' worst-frame SDRAM load
    averages about 1000 bytes a line instead of 1536 at the peak line; adds a DDR3 writer, a scan-out prefetch and a
    clear. The Limenko games are horizontal, so the DDR3 port is otherwise idle during play.
- Found for step 3: the game's VRAM, scroll and palette writes run to line 106 after the interrupt; MAME shows them
  all at the next interrupt, a raster with 24 blank lines shows part of them mid-frame. The user's choice: live VRAM
  and palette (no back copies), the scroll registers and layer enables latched at the interrupt (HACKS.md).
- Steps 3 and 4, done in simulation: `rtl/video/lm_video.sv` (the tile engine, drawing up to three lines ahead into
  four slots per layer), `rtl/video/lm_sprites.sv` and `rtl/video/lm_fb.sv` (the sprite draw into the DDR3 frame
  buffer, swapped at the interrupt). `scripts/lm_render_model.py` is pixel-identical to MAME on all 210 captured
  frames (`scripts/lm_capture.py`: five sets, attract and play, 21 frames each); `sim/lm_video_tb` is identical to
  the model on all 210, tiles and sprites. `sim/lm_tb` (CPU, real SDRAM controller, DDR3 model), 1511 frames:
  dynabomb's frames 1500-1510 pixel-identical to MAME's 1495-1505; legendoh's to 1497-1507 except lines 0-12 (the
  live palette and VRAM, HACKS.md); no late tile line, sprite draw or sprite line. The sprite draw uses the graphics
  port only while the tile engine is idle: before that legendoh overran 16,086 tile lines.
- Step 6, started: build `b22b9e5` (spotty's sound in): 32,319 ALMs, 410 of 553 M10K, clk_sys setup slack +1.246 ns. Flip Screen on the OSD (the chip has no flip register): `sim/lm_tb` dynabomb frames 700, 1500 and 1501 flipped equal the unflipped frames turned 180 degrees, every pixel. The one DIP per set ("Sound Enable", spotty's "Demo Sounds", IN2 bit 29) from the `.mra` `<switches>`. Stereo Mix hidden on spotty. Build `5f20b8e` with these: 32,197 ALMs, 410 M10K, +1.715 ns; deployed as `Limenko_30000001.rbf` with the six `.mra` files (`releases/`). On the board (`Limenko_stp` `a2ded84`, the zips copied to `/media/fat/games/mame/`): dynabomb shows its warning, attract and title screens (`debug/hw/lm/dynabomb_zip_1.png` to `_3.png`). The first launches were black because the zips were missing (LESSONS_LEARNED). The frame buffer's DDR3 reads are held from a reset until the copy starts (`0e5083c`; `sim/lm_top_tb +race=1` hangs the copy without it). Button names from MAME play (no manual found; `scripts/build_mra_lm.py`); legendoh's buttons 3 and 4 are not identified. The QS1000 sets were near silent on the board: the games set the chip's volume register far below misncrft's, as quiet in MAME. "Volume Boost" in the `.mra` `<switches>` (6 dB a step, defaults per set from their rendered levels; HACKS.md). Build `18f61b5`: 32,656 ALMs, 414 M10K, +1.250 ns; deployed as `Limenko_30000008.rbf` and released as `Arcade-Limenko_20261013.rbf`. On the board (the user): dynabomb, sb2003 and hrthouse play with sound at the defaults, the boost judged good; legendoh, sb2003a and spotty play too (`debug/hw/lm/legendoh_18f61b5.png`, `debug/hw/lm/spotty_18f61b5.png`): all six sets.
- Step 5, in sim: spotty's sound board, `rtl/sound/lm_spotty.sv` (jt8052 as the AT89C4051, the board's P1/P3 latch, jt6295 on SDRAM port 1). `sim/spotty_tb` against MAME's AT89C4051 trace: 2,000,000 instructions of attract (6 sound commands) and 1,300,000 with a coin at frame 150 (17 commands, 33 M6295 writes), 0 mismatches in state, M6295 writes and status reads. `sim/lm_tb` spotty, coin at 150, 420 frames: 17 commands, 33 M6295 writes with MAME's values, 274,762 sample bytes through SDRAM equal to the image; the commands come 1-3 frames apart from MAME's (main-CPU timing), so channel choices differ.
- Step 2, done (spotty's sound board is step 5): the `Limenko` and `Limenko_stp` revisions (`Limenko.sv`, `files_lm.qip`), `rtl/lm_main.sv`,
  `rtl/video/lm_video.sv` (RAMs, registers, raster; no picture yet), `vh_cpumem` and `vh_qs1000` in Limenko mode,
  `scripts/build_mra_lm.py` (six images identical to ROM_START; dynabomb's and spotty's regions identical to MAME's).
  `sim/lm_tb` from reset against MAME's instruction traces: sb2003 agrees for all 1,000,000; dynabomb, legendoh and
  hrthouse up to the RTL's first vblank interrupt (957,951, 284,101, 268,357); spotty up to 474,527, where MAME takes
  a timer interrupt the game set for the next TR tick. Over 300 frames every set issues one draw command a frame and
  sends sound commands; the 93C46 ends identical to MAME's in all five (three write it) and hrthouse's NVRAM is
  identical. The 8052 (`sim/qs1000_tb -GLM=1`) agrees with MAME for 3,000,000 instructions on dynabomb and sb2003,
  which read no banked data in that time, and for 14,000,000 on legendoh (101,208 external accesses checked, its
  bank-2 reads included). In `sim/lm_tb`, legendoh over 900 frames: 1,000 bank-2 reads through SDRAM, each equal
  to the image. `Limenko` build (`f1a9049`, seed 1, no tile or sprite engines yet): 28,740 ALMs, 377 of 553 M10K,
  clk_sys setup slack +1.053 ns. Inputs: dynabomb with a coin at frame 1500 changes the same six work-RAM bytes
  as MAME (the credit count among them, `scripts/mame/share_dump.lua`, `sim/lm_tb +ramdump`); without it, the RTL's
  2 MB of work RAM at frame 1800 differs from MAME's in 140 bytes.
- Raster: MAME gives 384 x 240 at 60 Hz and no raw timing; the board has 32, 24 and 20 MHz crystals. Proposed: 32 MHz / 4 =
  8 MHz pixels on `aoh`'s 512 x 264 raster (59.19 Hz), unverified (HACKS.md).
- Memory: the largest set, `legendoh`: program 2 MB, data 4 MB, graphics 18 MB, QS1000 samples 4 MB, main RAM 2 MB:
  30 MB, inside a 32 MB module. Its QS1000 program is 512 KB (eight 64 KB banks; 128 KB on the others): `u7` stays 128 KB
  of block RAM and the upper banks come from SDRAM, unless the M10K count leaves room for all of it.
- The second `.rbf`: Quartus revisions `Limenko` and `Limenko_stp` sharing the CPU, memory and sound RTL, with their own
  top-level options, main glue and video (`lm_main.sv`, `lm_video.sv`); `.mra` files with `<rbf>Limenko</rbf>` from
  `build_mra.py`; `sim/sys_tb` and a video bench on the Limenko top; `scripts/mame/regions.json` for the driver.
- Steps, each verified before the next: (1) captures, census and write sweep, the frame-buffer decision (to the user);
  (2) the revision, memory and I/O maps, EEPROM, inputs, the QS1000 banks: each set against MAME's PC trace from reset;
  (3) the tilemaps against MAME's frames; (4) the sprites against MAME's frames; (5) Spotty's sound board, if in scope;
  (6) hardware.

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
7. **Vamphalf release with `892dc77`** (SDRAM_CLK T - 2.0 ns, the default since): the SuperStation One reporter
   confirmed it cures Age Of Heroes' black screen; Age Of Heroes plays on the DE10-nano with it
   (`debug/hw/aoh_892dc77.png`). The 20261010 release predates it. Release an updated `.rbf` when the user asks.

## Next steps

1. User approval of this roadmap, and answers on open items 1, 3 and the first-target choice.
2. Phase 0 step 1: E1 core.
