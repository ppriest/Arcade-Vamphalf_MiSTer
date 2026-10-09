# Lessons Learned

Cumulative across five MiSTer arcade cores (Psikyo, Fuuki, Seta, Jaleco MegaSystem 32, Konami System
GX) built on the same toolchain (Quartus 17.0, ModelSim, Verilator), board (DE10-nano) and framework
(`sys/`, `hps_io`, Sorgelig's `sdram.sv`). Unmarked entries were established on Psikyo; `[Fuuki]`,
`[Seta]`, `[MS32]`, `[GX]`, `[HyperNG64]` mark the others.
To append: add the entry under the matching section, marked `[CoreName]`, in the same shape -- the
rule as the heading, the mechanism that made the wrong assumption plausible, the evidence that
settled it. Never edit an earlier core's entry to say what a later core found.
Module and script names in the evidence (`tilemap_line_engine`, `maincpu.sv`, `x1_001`,
`check_dips.py`, ...) belong to the core that found the rule; they are evidence, not scope, and will
not exist in a new repository.

| If you are about to... | Read |
| --- | --- |
| Vendor a module from jotego, furrtek or another core | "Diagnosis discipline", the first three entries |
| Instantiate TG68K.C, T80 or another vendored CPU | "CPU cores (TG68K.C, T80, vendored CPUs)" |
| Wire anything to the SDRAM controller or the ioctl port | "Memory transport: req/valid contracts, latency, byte order" and "MiSTer integration: reset, ioctl download, CONF_STR" |
| Size a RAM or add one | "Quartus synthesis gotchas", the block-RAM entries |
| Touch a sprite list, a line buffer or a vblank copy | "Sprite lists, line buffers and snapshots" |
| Write a `.mra` or decode a MAME ROM region | "ROM loading: .mra, byte order, deployment" and "ROM formats" |
| Build the first `.rbf` | "Timing closure", especially the first entry and the seed entry |
| Believe a hardware-vs-simulation divergence | "When simulation passes and hardware fails" |
| Write a testbench | "Testbench discipline" |
| Add a debug probe or a debug switch | "Debug instrumentation: how not to fool yourself" |
| Generate a reference from MAME | "Driving MAME as a reference generator (Lua)" |
| Deploy to the board or read anything back from it | "Hardware bring-up (MiSTer / DE10-nano)" |
| Run Quartus, ModelSim or Verilator at all | "Tooling and workflow" |

---

## Diagnosis discipline

### Suspect your own integration before any vendored module

TG68K.C, T80, `sdram.sv`, MRA/ROM loading, `hps_io` and `sys_top` ship in many working cores. One
investigation suspected, in order: SDRAM pin assignments (38/38 correct), SDRAM_CLK phase
(byte-identical output a quarter period apart), the burst-4 controller, the `.mra` interleave
("fixed" wrongly, then reverted) and TG68K's exception microcode (a testbench bug). The cause was
integration glue this project wrote. Rank hypotheses by how many shipping cores would have to be
broken for them to be true.

### [MS32] A web search returning nothing is not evidence that nothing exists

A roadmap was written around "no open FPGA NEC V60/V70 exists, so write one" -- a 32-bit CISC that
would have dominated the schedule. Two MiSTer cores ship one (`s32_v60`, in the Sega System 32 and
Model 1 cores), with testbenches, a MAME differential harness and an `IS_V70` parameter. The web
query for the CPU name returned Wikipedia and RISC-V projects; the question that finds it is *which
boards carry this chip, and has anyone built a core for those boards?* A CPU or sound core lives
inside the core of the machine that needed it, usually `rtl/cpu/<name>/`, and is rarely announced
standalone. Owe the same check to every sound chip and custom ASIC before scheduling it as
from-scratch work. The cost is asymmetric: "exists" when it does not wastes an afternoon of reading;
"does not exist" when it does commits the project to writing a CPU. Also: a grep of a primary opcode
table is not a survey of an ISA with escape opcodes (MAME's V60 FP ops dispatch through
`0x5C`/`0x5F` and were wrongly recorded as absent).

### Treat a conspicuous omission in a vendored module as deliberate

Upstream `sdram.v` has no reset port -- driven purely by `init` -- so a core reset cannot disturb
memory. A wrapper added one and created the ROM-download hazard under "MiSTer integration". Read the
upstream intent before overriding it.

### Read both halves of a mechanism before changing it: the draw loop AND the pixel op

Sprite depth ordering was inverted on the strength of MAME's draw loop alone (`sprite_ptr--` reads
as "draws backward, so entry 0 lands on top"). Never checked: the frame buffer's write is
unconditional so later writes win, and the append side of `get_sprites()` decides the net order.
Hardware inverted; reverted.

[MS32] Same trap, other polarity: `ms32_v.cpp` walks the list tail-to-head, but
`prio_zoom_transpen_raw` stamps priority 31 after the first opaque pixel so **the first sprite drawn
wins**; reverse iteration therefore puts the highest index on top. A Python model built on the loop
alone had 182 wrong pixels where letter sprites overlapped; with the pixel op read, pixel-exact. A
loop's direction says nothing until the write rule -- overwrite or first-wins -- is read beside it.
The RTL consequence: a line buffer that runs out of time must drop the sprites the chip draws last,
and which end that is comes from both halves.

### [MS32] A configuration flag that swaps wiring must be traced to every consumer, acknowledges included

`jaleco_ms32_sysctrl` with `set_invert_vblank_lines` swaps which callback fires at which line; the
driver wires the callbacks to levels 9 and 10 once, and the *ack* handlers call the callbacks by
name -- so under inversion the field ack clears the vblank interrupt. The RTL moved the acks with
the events; the one inverted set acked a level never set and took ~2,800 interrupts a frame. The
boot trace against MAME showed it at once (MAME took none in 300,000 accesses).

### Read the framework's source instead of inferring its behaviour

DIP switches were assumed to arrive through the status word, and two fixes were built on it -- a
`.CFG` generator and a `base="16"` attribute on `<switches>` -- both invented. One read of
`Main_MiSTer`'s `mra_loader.cpp` showed DIPs arrive as an ioctl download with index 254, saved to
`config/dips/<mra name>`, and `hexstr_to_char()` is always hex.

### Copy a driver's register expression including its operators

`psikyo_v.cpp` enables a layer with `enable(~layer_ctrl[layer] & 1)`. The RTL had `layer0_enable =
l0_ctrl[0]` -- right bit, wrong sense -- so both layers were off for every value the game writes and
the search went into fetch paths. Where MAME writes `~x & 1`, `!(x & 1)` or `x & 8 ? 0 : 15`, carry
the sense across and comment it: a polarity error passes review because the bit index looks correct.

### Make the hardware report its own state rather than re-reading the RTL

That polarity bug was found by extending the debug overlay to dump the video-register RAM: one
screenshot showed the control word the CPU wrote (`0x00D0`, bit 0 clear) beside the core's decoded
`layer_enable` of 0. Dump the register, not the intent.

### Prefer a hypothesis that predicts the number exactly

Tilemaps rendered correctly across exactly 28 columns of every scanline, backdrop for the other 292.
Chased as memory bandwidth. Cause: `tilemap_line_engine` had no `ce_pix` port and advanced one pixel
per `clk` (85.909 MHz) instead of per pixel clock (/12): 21 tiles x 16 px = 336 clk = 28 displayed
pixels. 28 of 320 is not "about an eighth", it is 336/12, and that division identifies the cause;
contention would give a ragged, load-dependent boundary. Corollary: any module feeding the
compositor directly consumes at `ce_pix`; only a module rendering *ahead* into a buffer -- line or
frame -- may run at full clock.

### Do not re-guess a sign from the reasoning that produced the wrong one

A one-tile X offset was patched with -16 on `base_x_scroll`; hardware moved the wrong way. The patch
was removed rather than flipped: the derivation was internally consistent and still wrong, so +16
would be a second guess wearing the first guess's confidence. The real cause was a
`gfxrom_req`/`gfxrom_valid` handshake bug.

### Add runtime A/B switches when the alternative is a rebuild per bisection step

Following `sprite_frame_buffer`'s documented contract (pulse `frame_swap` at vblank, wait for
`swap_done`) stopped the core booting: back-to-back rendering starved the SDRAM arbiter it shares
with CPU fetches. Isolated without rebuilding, using OSD render-disable switches: forcing both
tilemap layers off in the same bitstream still hung, leaving only the sequencing change.

### [MS32] A CPI measured on the power-on RAM test is a CPI of the RAM test

The first throughput figure for a vendored V70 was 8.48 cycles/instruction, within 6% of MAME's flat
8, and went into the clock decision. It was measured before interrupts were replayed, so the game
never left its RAM test: unrolled stores inside the core's retained fetch window. With interrupts
replayed the same six million accesses were 1.67 million instructions at 20.1 cycles each, 73% in
fetch refill. The tell was available: one access per instruction only happens in a store loop. When
a measurement beats the prior art by 2x, ask what the workload was, and put the workload in the same
sentence as the number.

### [Seta] Estimate the worst case from the hardware's iteration, not from the frames you looked at

A script over captured frames said 32-61 sprites per scanline; the design spent ~76 cycles per
sprite in a 6144-cycle budget and looked comfortable. The RTL's own per-line counter measured
155-544 on the busiest line of every capture: the chip walks all 512 entries every line, and a game
using 40 leaves the other 472 holding one stale Y, all on the same sixteen lines. Count what the
engine must *walk*, not what the game meant to draw, and instrument the RTL (`dbg_worst_line`, four
lines of Verilog, works on hardware too) rather than modelling the workload.


### [Seta] Ask what a table of per-game constants has in common before encoding it

Per-game sprite and tilemap offsets, and their flipped-screen counterparts, were carried as magic
numbers. The question worth asking first is whether they are one mechanism -- signal propagation
delay, a board-layout difference, a latch -- because a mechanism generalises to the sets nobody has
measured and a table does not.

### [Seta] Check every enable bit for inversion against the driver

"Are we sure no enable bits for tilemaps are inverted from MAME?" is a cheap question with a whole
class of wrong-looking frames behind it.

### [Seta] Sanity-check a reported clock against the board

A core reported as clocking at 96 MHz on a board whose CPU runs at 16 MHz is a wrong number, not a
fast core. Compare every derived clock with the driver's crystal before believing a timing report.

### [BallySente] Ask the simulation what the hardware symptom would look like

Shrike Avenger was black and silent on the board. The suspect was the 68000 second board, which the
6809 talks to through shared RAM. Zeroing the 68000's ROM in the bench image and running 120 frames
gave the same frame as the normal run (804 non-zero pixel bytes each, same write counts): a dead
68000 cannot black the screen, so the 6809 itself was not running. That cost two minutes and moved
the search to the load path, where the cause was (a release `.rbf` the MiSTer ran instead of the new
build). Before instrumenting hardware, break the suspect in simulation and see whether the symptom
matches.

## ROM loading: .mra, byte order, deployment

### [Seta] A `<dip>`'s `bits` is a range, "first,last", not a list

`mra_loader.cpp` reads it with `sscanf("%d,%d")`. A generator wrote every bit (`bits="8,9,10"`),
read as bits 8-9: every switch of three or more bits showed half its settings (30 of 34 sets). The
`.mra` files had been checked against MAME by a parser that read `bits` the way the generator wrote
it. Check with a script that parses as the loader does (`check_dips.py`) against `-listxml`. The
same review found `PORT_CONDITION` settings parsed into DSW labels by a lazy match on the line's
last `)`.

### Prove the interleave against MAME's disassembly offline, before building

"It boots" is weak evidence; a wrong map can boot far enough to look plausible. Every interleave
*derived* by reasoning about byte order was wrong; the working map came from copying a shipped
core's idiom. Reconstruct known words from the ROM files and score them against MAME's disassembly
(`lea $ffff7000.l,A0 -> 41F9 FFFF 7000`, ...): 18/18 for one model, 5/18 for the other, in seconds,
no hardware.

### [Vamphalf] A `ROM_REGION32_BE` graphics region is drawn in host byte order, not ROM_START's

`solitaire`'s "gfx" is `ROM_REGION32_BE` with `ROM_LOAD32_WORD_SWAP`, decoded `gfx_16x16x8_raw`.
`build_mra.py` reproduced the region's logical (big-endian) layout and reported "identical to
ROM_START"; on the board every 4-pixel group was mirrored. A raw layout draws from the region's
memory, which on a little-endian host holds each dword of that layout reversed. Rendering MAME's
captured sprite RAM through `render_model.py` decided it: 46,174 pixels differed with ROM_START's order,
0 with each dword reversed. Check an image against a MAME frame, not only against ROM_START, whenever
a region is not plain `ROM_REGION`.

### Treat the map-digit rule as mechanical and check it

mra-tools-c decrements each map digit and emits bytes in that order: `map="12"` is a pairwise swap,
`map="21"` verbatim. `ROM_LOAD16_WORD_SWAP` -> `<interleave output="16">` with `map="12"`; plain
`ROM_LOAD` -> bare `<part>`. Getting this backwards un-swaps tile ROMs silently (six MRAs rendered
tile layers as garbage while sprites looked fine). The inverse trap is real: a region that genuinely
is plain `ROM_LOAD` must not be "fixed".

### Do not "fix" a loader or file format without hardware evidence of wrong bytes

The maincpu interleave was rewritten on a mental model predicting a corrupt stack pointer. Every
test that seemed to indict it had run against an SDRAM that was never written -- garbage against
garbage. The rewrite was also inert: swapping the maps produced byte-identical output.

### Verify content against a hardware trace, and know what that does not prove

`verify_rom_trace.py` takes an on-hardware trace of ROM reads plus the zip, brute-forces plausible
interleaves and reports which reproduces the data. 128/128 for the shipped map proved the read path
byte-perfect at those addresses. It verifies *content*, not *address reach*: the trace address is
truncated, so a path aliasing high bits still scores 100%.

### A hardware-vs-image comparison cannot detect a wrong image

An earlier 128/128 match against the image assembled from the `.mra` was taken as proof the `.mra`
was right. Both sides were built from the same byte-order assumption. The tell was dismissed: the
reset vector had to be byte-swapped in the script to match MAME's `SP=FFFF8000 PC=00000400`. The CPU
received `PC=0x00000004`, executed the vector table as code and looped; the "sequential sweep from
0" that looked like a checksum was the CPU running off the end of the vectors.

### List `<rom index="1">` before `<rom index="0">` when a mod byte gates download-time logic

The mod byte is sent in file order and `mod_board` powers up 0. Listed after `<rom index="0">`, any
download-time consumer of it sees 0 for the whole download and silently does nothing; a runtime-only
consumer never exposes this. Confirmed by ear, same bitstream, byte last vs first.

### Gate every deploy on an XML well-formedness check

A `-->` that had already closed a comment left prose as character data containing `<- u127`; MiSTer
rejected the file: DIPs gone from the OSD, ROM never loaded, black screen, every symptom pointing at
the RTL, the only clue an on-screen "XML parse". `python scripts/validate_mra.py "releases/*.mra" &&
<copy>`; it also flags stray element text. MiSTer's parser is more lenient than a strict one, so "it
loaded before" is not evidence of well-formedness.

### Force a genuine reload when testing an `.mra` change

Re-launching an already-loaded game reuses the cached ROM; an `.mra` edit alone gives a
byte-identical trace, which nearly discarded a correct fix. Bounce through `menu.rbf` via the Remote
API (`POST /api/launch`) before relaunching.

### Put the `.rbf` in the top-level cores directory

`.mra` references it by bare `<rbf>` name, resolved by prefix match in `/media/fat/_Arcade/cores/`
only. Misplaced, the result is a silent flash-and-return-to-menu before ROM loading begins.

### Do not hand-write a `.CFG`

`/media/fat/config/<setname>.CFG` is the whole 128-bit status word, little-endian, and the `.mra`'s
`<switches>` bytes live in it (byte 0 -> `status[23:16]`, upward). Writing 16 bytes with one debug
bit set zeroes every DIP -- here silently enabling Service Mode, twice. Use a read-modify-write
script. Per-game defaults are each `.mra`'s `<switches default="...">`. A DIP that looks harmless
can hang a game (gunbird polls a region bit and spins until it clears).

### Make the all-zero configuration the correct one

A fresh or missing `.CFG` is all zeroes, so any OSD option that must be on for correct behaviour is
bit-inverted with its OSD order to match (`On,Off`). Otherwise every first-run user gets the
degraded path.

### [Seta] A correct `.mra` DIP block still needs `"DIP;"` in CONF_STR

Switches were right in all 31 `.mra` files, decoded by the core, every game ran with correct
defaults -- and the OSD had no DIP page for the whole project. The framework renders that page only
when CONF_STR asks for it; the switches are delivered (ioctl index 254) either way, so nothing
misbehaves. `check_dips.py` and the hardware sweep both passed; nothing looked at the menu. Verify
the end the user touches.

### Find a ROM by its CRC, not by its filename, everywhere

The CRC identifies a dump; the filename is one zip's spelling of it. Four rules follow, and they
are one rule: a testbench and the board must accept exactly the same zips, or a bench passes on
a set the hardware refuses.

- **Every `<part>` in a generated `.mra` carries its `crc`** from the driver's `ROM_START`. The
  `md5="none"` on the `<rom>` element skips the whole-image hash and is not a substitute.
- **Look the part up by CRC first, by name second** (`scripts/mra.py`). `zipfile` exposes each
  entry's stored CRC32, so the search costs no reads. A renamed dump then still loads.
- **Ignore any directory structure inside the zip**: match the basename.
- **Name the zips as a cascade**, `zip="set.zip|parent.zip|bios.zip"`: the set's own zip, then the
  parent or merged zip, then a BIOS zip, first hit wins. Split, merged and renamed sets all load.
- **[BallySente] A `<switches default>` is only reliable in its first four bytes.** Main_MiSTer
  builds it with `dip_def |= binary[i] << (i * 8)` (`support/arcade/mra_loader.cpp`), an `int`
  shift: a byte 3 of 0x80 or more sign-extends over bits 32-63, and a fifth byte is shifted out.
  BallySente's fake Flip Screen DIP at bit 32 with `default="...,FF,FE"` therefore started On in
  all 40 sets. Keep every DIP, real or fake, in bits 0-31; check a generated default by applying
  that arithmetic, not by reading the hex.

## ROM formats

### [Seta] A `ROM_LOAD24_*`-style macro may be driver-local -- read its definition, not its name

seta.cpp defines `ROM_LOAD24_BYTE` as `ROMX_LOAD(..., ROM_SKIP(2))` and `ROM_LOAD24_WORD_SWAP` as
`ROMX_LOAD(..., ROM_GROUPWORD|ROM_REVERSE|ROM_SKIP(1))`; loaded at offsets 0 and 1 they build 3-byte
groups (`dest[3g]=byte[g]; dest[3g+1]=word[2g+1]; dest[3g+2]=word[2g]`). Verified offline: file
sizes sum to the declared region and tiles decode as artwork with up to 26 of 64 pens rather than
noise. Settling this before writing the `.mra` cost minutes.

### [Seta] A `gfx_layout` transcription can be checked without any ROM

A well-formed layout uses every bit of a tile exactly once: map every (x, y, plane) to its offset
and check `width*height*planes` distinct offsets cover `[0, charincrement)` with no gaps. Catches a
mistyped `STEP` or stride before any ROM is available, independently of whether the art "looks
right" -- the judgement a plausible-but-wrong layout defeats.

### [Seta] In a `gfx_layout`, the first plane listed is the MSB of the pen; `TILE_FLIPXY` transposes its two bits

Reading `{ STEP4(0,4) }` as plane 0 -> bit 0 gives a *recognisable* picture with a third of the
pixels wrong, which reads as a subtly bad layout rather than an inverted bit order. Scoring sixteen
candidate layouts against MAME's render: every ascending-plane variant 33-34%, MSB-first 100.00%.
And `TILE_FLIPXY(xy) = ((xy&2)>>1) | ((xy&1)<<1)` with `TILE_FLIPX=1`, `TILE_FLIPY=2`: for
`TILE_FLIPXY((w & 0xc000) >> 14)`, bit 14 is FLIPY and bit 15 FLIPX. That one costs 2-5% of pixels
only on frames with flipped tiles, so it looked like per-game configuration. What found it was
asking what the wrong pixels had in common (all in tiles with non-zero flip bits), not which games
were wrong. Two cheap first questions: are the wrong pixels in the layer or under sprites, and do
they cluster?

### [GX] One set cannot show a region-split formula that happens to agree on its own sizes

`k055673.cpp` splits a sprite region as `size4 = (bytes >> 20) / 5 << 22`, so a region that is not a
multiple of 5 MB is partly unread; a layout that assumed 5-byte rows put the fifth bytes 0xcccc rows
off. The composed memory bench run on a *second* set is what found it. Run every region-layout check
on at least two sets of different sizes.

### [HyperNG64] Check a large set's regions for byte-identical copies before sizing memory

`hng64` sets declare `textures0..3` as four 16 MB regions; in `sams64` all four load the same
four ROMs (same CRCs). The board duplicates them for parallel access; the core needs one copy,
48 MB less per set. Compare CRCs across regions in `-listxml` before deciding a set does not fit.

## MiSTer integration: reset, ioctl download, CONF_STR

### Never hold the memory path in the core reset

MiSTer holds core `RESET` for the ENTIRE ROM download. Passing the composite reset into the SDRAM
backend pinned the download FSM in idle: the HPS delivered every byte, the accept condition looked
perfect, and not one `CMD_WRITE` reached the chip. Keep two domains: `core_reset = reset |
ioctl_download` gates CPU and video; the memory backend keeps plain `reset`. Signature: a downstream
FSM stuck in idle while its trigger input is visibly pulsing.

[MS32] The same for anything a download writes: `ms32_video`'s registers were `if (reset) ... else
if (vreg_we)`, and the capture blob's scroll and brightness writes arrive during the download -- all
dropped on the board, matched on the bench, which does not hold reset across the load.

### [MS32] Put the OSD Reset entries before the joystick lines in CONF_STR

`"T[0],Reset;"` and `"R[0],Reset and close OSD;"` placed after `"J1,..."`/`"jn,..."` appeared in the
OSD and did nothing. The ISSP probe counted 0 rises of `status[0]` per press; moved above `J1`, 1
rise, 1 core reset. (The same commit dropped two empty names from `jn`, so which change mattered is
not isolated.) When an OSD entry appears but its bit never moves, count the bit on the board before
reading the core's logic, and copy a working core's CONF_STR order.

### Measure at the pins, not at the intent

The decisive measurement for the reset bug was counting real commands on `{SDRAM_nRAS, SDRAM_nCAS,
SDRAM_nWE}`. Delivery counters and FSM accept-condition counters both looked perfect; only the pin
count showed zero writes. Measure the last observable stage.

## Memory transport: req/valid contracts, latency, byte order

### Give a registered RAM its full read latency before consuming the data

An FSM that registers a RAM address in one state and reads data in the next gets the PREVIOUS
address's data. The row-scroll table showed it: every scanline scrolled by its predecessor's entry,
invisible while the table varied smoothly. The port comment said "1-cycle synchronous read latency";
the FSM did not honour it, and the bench ran with row-scroll disabled. State the latency in the port
comment and spend the wait state; model bench RAMs as registered reads so a behavioural model cannot
mask it.

[Seta] Not under a clock enable: a block stepped one state per `ce` (one clock in six) with `q <=
mem[addr]` every clock has its read complete five clocks before the next step, so each state
captures its own byte with no wait state. Adding one anyway shifted every capture by a register
(`r0` got register 1), which read as a dead engine. Write the `CE_DIV > 1` dependency beside the
code.

### Deassert a request combinationally on `valid`

`tilemap_line_engine` cleared `gfxrom_req` one clock AFTER `gfxrom_valid`; `sdram_phy.sv` returns to
idle on the valid cycle and samples the still-high request, launching a duplicate. Every later
response belonged to the previous request: cell N drew N-1's shape with N's colour. `assign
gfxrom_req = gfxrom_req_r & ~gfxrom_valid;`. Proved by a bench wiring the real transport, whose
trace showed the phy serving the previous address from the second fetch of every line.

### Hold every request until acknowledged

A req/ack round-robin arbiter needs every port on hold-until-acknowledged, not a one-shot pulse: a
pulse arriving while another client is served is silently lost. `ioctl_wr` from `hps_io` is a
genuine one-shot and needs a wrapper converting it with `ioctl_wait` backpressure.

[MS32] The bench-side twin: a memory model must not accept on the clock its `valid` leaves.
`sdram_narrow_bridge` holds `g_req` until the clock after `g_valid`; a granule model that accepted
whenever idle latched a second copy of every miss and answered the next request with a stale granule
-- 9,674 wrong bytes in 50 ms, looking like a CPU that ran fine and then wandered. A checker
comparing every byte handed to the CPU against the ROM at the requested address found it in one run;
keep one in any bench that models a transport.

### Treat any direct, non-arbitrated connection to a req/valid transport as suspect

`sdram_phy.sv` asserts `valid` and returns to idle in the same cycle; arbitrated consumers get a
cycle of margin from the arbiter. A single-client port wired straight to the phy ("no arbiter
needed") silently returned the previous transaction's data under contention -- not a hang, sprite
corruption. Fixed with a pulse shim reproducing the arbiter's margin. Third occurrence of the class
in one project.

### Clear a request-tracking flag on the bus cycle ending, not on the data-valid pulse

A `rom_pending` flag must clear when the CPU's bus cycle ends, if the CPU can hold it open longer
than the fetch (a 68k holds `as_n` low after DTACK). Clearing early fires a spurious second request;
under contention another client wins that slot and overwrites the shared read-data register. Looked
like SDRAM corruption; was the CPU wrapper's request lifecycle.

### Capture read data on the valid pulse -- nothing in the path latches it

From `sdram.sv`'s `dout` to the CPU bus is combinational and valid is one cycle:
`dout0`/`dout1`/`dout2` are one shared register, the arbiter and the narrow bridge add no register.
`maincpu.sv` got away with it only because TG68K.C re-captures `DATA` every clock while parked -- an
alignment holding by exactly one cycle. Any change to how often a consumer samples (a clock enable,
another domain, a pipeline stage) requires latching data and ready first. Testbenches must sample
inside their own ack-triggered branch or they show 100% failures that look like RTL.

### DTACK/ready must be a held level, never a pulse, for any clock-enabled CPU

A core stepping at 16 MHz in an 85.9 MHz fabric looks at DTACK every ~5.4 cycles; a one-cycle
assertion is missed and the bus cycle hangs. Check every ready/ack feeding a gated core.

### Fix byte order at the seam, with a dedicated adapter

Endianness bugs live between two independently correct modules: `sdram.sv` packs bytes ascending,
gfx consumers assumed MAME's MSB-first, program ROM needs big-endian while the bridge's generic path
is little-endian (correct for genuinely LE regions). Add an adapter per seam rather than changing a
shared convention under its other consumers. Uniform or zero test content is invariant under byte
order; budget a real-content test.

### Choose SDRAM over DDRAM for hard real-time fetch budgets

`DDRAM_*` is documented "for non-critical time purposes" with an unbounded worst case; measured ~26
cycles against a 16-cycle-per-tile budget under two-consumer contention. `SDRAM_*` gives bounded
~6-7 cycles. If a design starts on DDRAM for convenience, budget the pivot.

### Verify a burst extension against a command-decoding chip model, not a latency stub

Adding burst-4 to a non-bursting controller needs a model decoding `nRAS`/`nCAS`/`nWE`/`SDRAM_A`. It
caught: the row/column split needed swapping (a burst auto-increments the *column*; the non-bursting
upstream had it the other way, harmless until bursting exists); the model ignoring `DQML`/`DQMH`; an
off-by-one in burst-read CAS timing.

### Size a prefetch buffer for correlated consumers, not average bandwidth

Two layers with identical scanline timing request in lockstep; a 2-entry ping-pong absorbed one
simultaneous loss and one tile in five stalled. A parameterized N-entry ring fixed the tested
pattern, not the general case.

### [Seta] Look for the permutation that lives above byte granularity

A sprite row cost four SDRAM round trips because `RGN_FRAC(1,2)` puts its words half a region apart;
"rewrite the data" looked like a byte shuffle in the loader. Writing source and destination byte
addresses side by side showed the plane bit is the low bit of both -- nothing below a word moves, so
it is a free word-address permutation. Reads per row 4 -> 1; sprites per line at latency 24, 43 ->
108. Write both address expressions out before assuming the data must be touched.

### [Seta] A bidirectional bus captured into several lane registers gets one I/O register and the rest a lottery

Every build after a known-good one died in the power-on RAM test, on RTL changes provably inert for
those games. `sdram.sv` captured each burst lane straight from `SDRAM_DQ` into its own register; a
pin has ONE input register, so `FAST_INPUT_REGISTER` can honour one lane per pin and the other three
capture in the fabric on an untimed pin-to-register path. Constrain the port and STA says it:
`SDRAM_DQ[8] -> dout[8]` through 10.6 ns of interconnect, worst path in the design; the lane that
won the I/O cell, 0.000 ns. Which lane wins is the fit's choice, so any change moves it -- the seed
sensitivity, with its cause. Fix: capture the bus ONCE, unconditionally (`dq_in <= SDRAM_DQ`) and
take lanes a cycle later. A per-bit oracle (`sdram_check.py`, last granule fetched vs the ROM, over
JTAG) made the bisect cheap: "bit 8, first beat, half the time" named the register. When an inert
change breaks hardware and STA is clean, look for a path STA is not timing: the "Packed Register"
table and "Unconstrained Input Ports".

### [GX] A one-cycle handshake into a slower clock-enabled domain must land on that domain's edge

A kernel at 24 MHz samples its clock enable on alternate 48 MHz cycles. An access unit's `ready` was
set in whichever cycle a peripheral's `busy` dropped; half of those were not kernel edges, the ack
was lost, the kernel repeated its write, and the peripheral ran the same command forever. The bench
never showed it because its ROM answered every fetch in an even number of clocks; on the board SDRAM
latency parity varies. `ready` is now held until a kernel edge, and the bench ROM adds a clock to
every other fetch (`+ROM_JITTER`). When a fixed-latency simulation passes and the board does not,
vary the latencies' parity first.

### [GX] A register port without byte enables passes every capture-driven bench

A 16-bit register port took a whole word per write. Benches loading registers from a MAME capture
write whole words, so they passed. The game writes those registers a byte at a time; the 68000
carries the byte on both halves, so `0x01` stored `0x0101`, the sprite bank became 1 and every
sprite fetched blank ROM -- with DMA, scan and line-buffer writes all at full count. Before wiring a
register port to a CPU, list the game's write masks for it from MAME's trace.

### [Seta] A region whose base is not aligned to its size must be indexed by subtraction, not masking

Every region was indexed by low address bits, right only when the base's low bits are zero. A
palette at `0x?00400` put entry 0 at index 0x200: black sprites, right art wrong colours, on every
board with that base and in no simulation (benches wrote the palette RAM directly).

## Sprite lists, line buffers and snapshots

### A swap is not a copy

`spriteram_dbuf` ping-ponged two banks, arguing this equals MAME's copy as long as the CPU never
touches the render bank. Under ping-pong the CPU's view alternates, so any entry not rewritten every
frame reads back two frames old -- including the end-of-list marker. A long frame inherited a stale
marker and rendered far more sprites. A real copy removed the ghosting.

### [Seta] A snapshot is a race with whoever writes the thing being copied

The copy walked 9216 words one a cycle and started on vblank -- the same line the vblank handler
rewrites the list -- so half the records came from each frame. The glitch vanished with the CPU
paused: a fault that needs the CPU running and is not in the CPU is a race with something the CPU
writes. Golden-frame benches cannot see it; their RAM is static. Start the copy when the writer is
quiet (late in blanking) AND make it atomic against writes that land anyway (write-through to the
copy, cursor holds). The bench writes behind the cursor; with write-through disabled it loses 96 of
96 words.

### [Seta] A golden frame taken after vblank cannot check what pairs with what across vblank

On boards where the chip copies code/X at vblank and reads Y live, MAME draws and then copies, so a
frame pairs Y with codes copied a vblank earlier. The core copied and then snapshotted. MAME's
notifier runs after the copy and `video:snapshot()` re-renders from that state -- exactly the core's
wrong pairing. Replaying the write log over 401 frames and rendering both pairings found 94
differing. When a device buffers some state and not other state, the bench must run two frames.
Three reorderings each fixed one game and broke another: moving the copy is placing it against when
the CPU writes, and the core's CPU wrote earlier in the frame than MAME's. Check the writer's timing
against the reference before moving an event relative to it.

### [Fuuki] Freezing the display LIST is not freezing the display

The once-per-frame candidate list was frozen; each scanline then re-read the records from live RAM
while the game rewrote them, so a sprite changed tile mid-frame or dropped for a frame. Everything a
per-line renderer reads during the frame -- records and the registers that qualify them -- comes
from one snapshot at the frame boundary.

### [Seta] A double buffer puts the renderer TWO lines ahead, not one

"At the start of line L, render L+1" is off by one: the buffer written during L is read during L+1,
and `line_start` fires at the end of L-1. The picture displayed one line late showed as stray pixels
along every horizontal edge (3,560 of 92,160, on 148 of 240 lines), which reads as sprite dropout.
Shifting the captured frame by one line and re-diffing gave zero. When a picture is *nearly* right,
check rigid transforms before reading any logic; the same move settled MAME's snapshot orientation.

### [Seta] Put a time budget just below the period, not at it

At exactly the line period the cutoff and the buffer swap race; the swap arriving first took the
engine's "started while busy" path, restarting it mid-render, 49 lines a frame. 44 cycles below the
period: zero overruns, 49 clean cutoffs, identical output. A deadline coinciding with the event it
pre-empts is not a deadline.

### [Seta] A back-to-front line buffer cannot drop the right sprites

An engine drawing back-to-front and stopping on time-out drops the sprites it has not reached: the
lowest indices, which the chip draws last and puts on top. Overflow deleted the player and kept the
background. Stop encoding priority in write order: tag each buffer entry with the index that wrote
it, write only when the new index is lower, walk front to back. Running out of time then drops the
bottom-most sprites.

### [GX] A per-line object scan that runs out of time drops sprites without an error

A vendored scan (`jt053246_scan`) walks all entries every line and restarts wherever it got to; late
entries are simply not drawn, the only trace a `$display("Obj scan did not finish")`. A line buffer
at two clocks per pixel lost the large text sprites on 94 lines, looking like a missing layer. Grep
every sprite bench log for such messages and count them as failures; when a sprite is missing, look
at where it sits in the table before its attributes.

### [GX] `jtframe_objdraw_gate`'s readout counter needs `hs` across the `hdump` wrap

With `HFIX=1` the buffer read counter re-synchronises to `hdump` only while `hs` is high. A bench
with `hs` before the wrap drew every sprite and displayed none: the counter ran on into the half of
the buffer nothing writes. "Thousands of buffer writes, zero pixels out" says read side; a counter
of non-blank values read back found it in one run.


### [Seta] Latch the sprite list and the video registers at the same point unless evidence separates them

One core latched sprite RAM in vblank and the tilemap registers at frame start, for no recorded
reason; the difference was noticed as a question ("why not the same?") rather than as a bug. Pick
one snapshot point from the write sweep, apply it to every array the frame needs, and record why if
any array differs.

### [Seta] A glitch that appears only while the game runs, never when paused, is a buffering fault

Wrong sprite tiles and orientations in motion, correct in a frozen frame, means the list or its
registers are read while being written, not that the decode is wrong. Look at the snapshot point
and the double-buffer ownership before touching the graphics path.

### [Fuuki] Buffer the sprite list and render per line; do not add a frame buffer

A whole-frame buffer was retired: the shape that works is the sibling cores' one, sprite RAM
buffered once a frame, a per-frame candidate list, a per-scanline engine, a double-buffered line
buffer.

### [Fuuki] For raster effects, fire the line interrupt every line and buffer attributes into the line renderer

Waiting a couple of scanlines to buffer, or servicing the interrupt late, shows up as one row of a
cloud scrolling independently of the rest. NeoGeo_MiSTer and jotego's jtcps are the reference
implementations for the per-line interrupt plus attribute buffering pattern.

### [Fuuki] A one-line vertical offset between layers is the interrupt's line numbering, not its timing

Sprites a scanline low (and credit text clipped at the bottom) was a 0- versus 1-based raster row,
not an interrupt fired too late; moving the interrupt a line earlier would not have fixed the text.
Establish which row the handler believes it is servicing before shifting anything.

## When simulation passes and hardware fails

### Re-run the failing case with the production transport in place of behavioural models

The `gfxrom_req` duplicate fired in module-level simulation too, but the short-latency ROM model
answered while the FSM was between states, so it was dropped. The real controller's ~12-cycle
latency lands it in the next wait state. The bench that found it wired the real SDRAM top plus a
chip model into the screen path. When sim and hardware disagree and timing is clean, swap
behavioural models for the real transport before blaming synthesis.

### Ask of every stimulus whether it is the shape the real system produces

`tb_maincpu.sv` pulsed `vblank` for one clock; hardware holds it ~205,000 cycles. The IRQ logic was
`if (vblank) set; else if (iack) clear;`, so an acknowledge arriving while vblank was high --
always, on hardware -- was discarded and the CPU re-entered the ISR after every `RTE`. Same blind
spot: a bench drives its own reset and download, so it never reproduces MiSTer holding RESET across
a transfer; `ioctl_index` hardcoded to 0.

### Give a held interrupt line's acknowledge priority

Match MAME's `irq4_line_hold`: assert on the rising edge, hold until acknowledged, acknowledge wins.
Ask of every level-sensitive input whether it is still asserted when the consumer responds.

### Check static timing before pursuing any hardware-vs-simulation divergence

The cheapest check, and it was skipped. See "Timing closure".

### [GX] An `initial` value on a register array is not a power-up value under Power-Up Don't Care

A 93C46 model blanked its array with an `initial` loop. Quartus built it as 1,084 registers (map
report; no `.mif`), and the `.qsf` has `Power-Up Don't Care`, letting the fitter choose each state.
Verilator honours `initial`, so every simulation read FFFF; on the board, games that only read the
EEPROM reported it BAD. A state that must be known at reset is written at reset. When simulation
passes and the board does not, list what the simulator initialises that the fitter was told it need
not.

### [GX] A game that reads its EEPROM without writing it needs the driver's default image

Most `konamigx.cpp` sets carry a `ROM_REGION( 0x80, "eeprom" )` `.nv`, copied by `nvram_default`
when no `nvram/<set>/eeprom` exists. A game that reads all 64 words at its RAM check and never
writes reported BAD on a blank part -- and in MAME with a blank `nvram` file, the same screen. The
RTL's transaction stream matched MAME's blank run word for word: the model was right, the contents
wrong. The `.mra` now carries the region as `<rom index="2">`. Before reading a board failure as a
model fault, run the reference with the board's starting state.

### [GX] A stand-in for a sound CPU must change state, not echo a value

A game keeps sixteen frames of the sound CPU's status nibble and, if all equal, resets the sound CPU
and stops its command queue, which the attract sequence waits on. A stand-in that echoed the last
command was constant; the game sat on its title on the board and left it in MAME by frame 2700.
Found by disassembling every reader of the status register, not by guessing the value. The stand-in
now moves the nibble every frame.

### [Seta] An unbacked RAM region does not read as garbage, it reads as a failed power-on test

A boot writes `0x5555` to a region, reads it back and branches. Decoded but unbacked it read 0, the
test failed, and the CPU ran a *different program* from MAME's, correctly; the bench reported a
stall 25 reads in, which looks like bus sequencing. When a boot diverges, ask what the code was
*testing*. When standing up a CPU bench, back every region the map backs.

### [Seta] Back the RAM a power-on test walks at the size the map declares, even the part nothing else uses

Three instances. (1) Boards put a 16 KB or 64 KB SRAM behind a palette or VRAM of which the custom
chip uses a window; the self-test walks the chip. A core decoding only the window passes every
simulation (benches drive the chips, not the tests) and shows PALETTE RAM NG on hardware -- or a
black screen with the CPU running. The chip size varies by board within one map family; a MAME write
tap over six sets found only one's self-test writing above the window, and it is still what the
board has. (2) `zingzip_map` declares two work-RAM blocks; the core mirrored the second onto the
first. Fifteen of sixteen sets never touch it; the one that does had its RAM test clear the first
block *including the return address on the stack*, `rts` popped zero, the CPU ran the vector table
as `ori.b` pairs and halted in the driver's `bra.s *`. A stack inside a mirrored region turns
aliasing into a wild jump far from the cause, and the self-test PASSED because the alias was
self-consistent. Count the `.ram()` lines, not the bytes the game seems to use. (3) A test that
fills 0xAA, verifies, then 0x55, then 0x00 gives up at the first unbacked verify and leaves 0xAAAA
in both layers; the screen said OK anyway. Pinned without probes: every background colour in the
screenshot was MAME's palette entry `0xAAAA & 0x1f`. Where real storage does not fit (~90 M10K), a
mirror passes a fill-then-verify test if a write tap shows nothing else writes there.

### [BallySente] A vendored CPU may be simulated from a different source than Quartus builds

FX68K's upstream source does not build under Verilator, so the bench runs the Verilator port (from
another MiSTer core) while Quartus synthesises Jorge Cwik's upstream files; the two differ
throughout. A bench pass then says nothing about the CPU that is on the board. Record which source
each tool uses (`PROVENANCE.md`), and when only that CPU's behaviour differs on hardware, suspect the
pair before the RTL around it.

## Testbench discipline

- **[Vamphalf] Replay the CPU's boot trace against the whole board, not only the CPU bench.** The
  CPU bench serves every access from the trace, so it cannot see a decode, a cache or a RAM size.
  The same 1,000,000-instruction MAME trace compared against the retired PCs of the full board
  (real SDRAM controller, caches, decode) diverged at instruction 1,919, in a sprite-RAM test that
  walks 256 KB where the core backed 64 KB. Compare the PC after each instruction (`retire_npc`
  against the next record's PC); an exception entry that the CPU core reports differently from the
  trace makes a compare of "this instruction's PC" fail where nothing is wrong.
- **[Vamphalf] Check a sound engine inside the board by replaying the board's own register writes
  through the model.** The whole-board bench's audio cannot be compared with MAME sample for
  sample: its sound CPU reaches each write at a different time (up to 142 ticks off MAME's spacing after
  100 writes). Logging the bench's writes in the model's input format and replaying them through the
  model gives an exact reference for the RTL engine in place, with the real SDRAM controller's
  latency and the other ports' traffic: 6.9M ticks, 0 differences (`scripts/qs1000_mix_compare.py`).
  The write log against MAME's capture separately checks the sound CPU's program flow (1,563 of
  1,563 writes identical in register, value and order).
- **[BallySente] A vendored module's compile WARNING can be a latent fatal.** T80 has carried a
  vcom-1275 "arguments of overloaded `and` are not the same length" warning through several
  sibling cores, noted and ignored. It is a real bug: `T80.vhd:685` masks a 9-bit vector with a
  4-bit literal in the P/V flag path for `INI`/`IND`/`OUTI`/`OUTD`, and ModelSim turns it into a
  run-time abort (vsim-3424) the first time a block I/O instruction executes. Cores whose Z80
  never runs one -- which is most of them -- see only the warning. The Bally/Sente 6VB sound
  program does run them, and the boot died partway through, at a point that looked like the
  program simply taking a long time. Triage a vendored module's compile warnings before a long
  run, not after it fails; and when a simulation stops making progress, check for a fatal in the
  log rather than assuming the model is just slow.
- **Use `do @(posedge clk); while (signal);`, never `while (signal) @(posedge clk);`.** The latter
  races an `always_ff` updating the signal on the same edge and either deadlocks or returns before
  the transaction started. Recurred in three benches before being recognised as systemic.
- **Grep the log for `readmem` before touching RTL when a testbench fails wholesale.** `vsim` from
  the wrong directory made `$readmemh` find nothing; the ROM stayed zero and every check failed.
  ModelSim reports it as `** Warning: (vsim-7) Failed to open readmem file`, not an error. Failure
  in *every* check is the signature. `$readmemh` paths are relative to the simulator's CWD.
- **Write preloaded vectors and tables AFTER `$readmemh`.** A bench installed the autovector at
  `0x70`, then `$readmemh`'d an image whose empty `0x70`-`0xFF` region zeroed it. The CPU took the
  interrupt, read a zero vector, executed zeroes. Recorded in two documents as a TG68K.C microcode
  bug.
- **Confirm which column is address and which is data before blaming a CPU.** The trigger for that
  conclusion was reading `0x00000000` as the fetch address; it was the *data* at `0x70`. Suspect a
  zeroed vector table long before microcode.
- **Do not assert on a sticky error output with a benign first trigger.** `fetch_overrun` fires
  unavoidably on the first line after reset; replicate the trigger with a non-sticky per-cycle
  check.
- **[Fuuki] A block-local variable WITH an initializer is implicitly STATIC, and the initializer
  runs once before time 0.** `bit seq_ok = (...)` inside `begin`/`end` evaluated at elaboration and
  stayed false. ModelSim names it (`vlog-2244: Variable ... is implicitly static`), skipped as
  noise. Split declaration from assignment.
- **[Fuuki] Before concluding an interrupt path is broken, check the CPU's interrupt MASK.** A 68000
  boots at mask 7; one game still had it after 952 fetches. Expose the mask, and test the IRQ path
  with a synthetic program that enables interrupts.
- **Re-run the regression on a clean stash before debugging your change.** A stale fixture looks
  identical to a regression.
- **Write a smoke test (elaborate, run N cycles, check for X-propagation) before a functional test**
  on any new top-level integration.
- **[Seta] Never write a literal into a vector that does not start at bit 0.** `logic [7:1] hold`
  indexes levels; `7'b0000110` numbers from the MSB down to index 1 and means levels 3 and 2. Checks
  that used a level the wrong pattern also set PASSED, so two of four failing read as a
  partly-broken module. Use a helper that takes level numbers.
- **[Seta] A behavioural ROM in a bench must speak the transport's byte order.** A hand-assembled
  program written the readable way round gave the CPU a swapped stack pointer, which ran through
  NOPs across the address space and looked like a CPU that never started. Say in the bench where the
  swap happens and why.
- **[Seta] Backpressure: assert the write in the SAME step the wait clears.** `while (ioctl_wait)
  @(posedge clk); @(posedge clk); ioctl_wr <= 1;` -- the extra edge lets `ioctl_wait` rise again and
  the write is lost. Presented as every ODD word wrong, which reads as a byte-pairing fault in
  `sdram_download`. The correct driver already existed in an earlier bench; copy the driver rather
  than rewriting the handshake.
- **[Seta] A liveness test needs a timescale, or it reports failure for being early.** After six
  simulated frames: no palette write, no sprite write, no interrupt, four failures. MAME does the
  same thing in six frames -- the game's RAM fill runs past its 400,000th access. Measure T against
  the reference (`mame_capture.py --boot-trace N`); fail only on what being early cannot explain
  (CPU not running, no video lines) and REPORT the rest.
- **[Seta] The same width truncation, in the testbench.** A ROM indexed with `[19:3]` where the
  array needs `[20:3]` passed on a 0.5 MB region and failed on a 2 MB one as wrong pens in one game
  of eight. Exactly the biggest asset failing is the tell; an in-range part-select draws no warning.
  Check widths against *that* game's sizes.
- **[Seta] A free-running engine emits samples before your test has finished configuring it.**
  Loading an 8 KB register image through the CPU port takes longer than one output period, so the
  RTL's first samples came from a zeroed register file and the compare failed at sample 0, looking
  like a dead engine. Load with the block in reset, release, compare from there; whatever reset
  suppresses (key-on edges) needs its own directed check.
- **[Seta] Do not reach into the DUT with `force`/`release` when an ordinary write will do.** A
  forced accumulator reported a failure the RTL did not have. Drive the DUT the way hardware drives
  it.
- **[Seta] A branch no capture exercises is not covered, however many runs pass.** 72/72 runs
  identical to the model; in all 24 captures the flip bit was clear, so the flipped half had never
  been compared. A DIP set from the autoboot script (after reset) was silently not acted on and the
  sweep printed PASS on unflipped frames. Verify the effect, not the action: the sweep now fails any
  frame whose control byte lacks the bit. (Also: byte-wide registers on odd addresses are byte 1 of
  a big-endian word dump.)
- **[Fuuki] A testbench that models the memory the core instantiates cannot see the core's
  indexing.** 84/84 boot fetches passed with the bench's own RAM macro; the core's work RAM indexed
  `[16:1]` -- halved twice -- so consecutive words shared an entry. Nothing read RAM back until the
  first `rte`, which popped SR=0 PC=0. Where a bench substitutes its own model for a block, add a
  check that runs the real block or treat it as unverified.
- **[Fuuki] When widening an address, grep for every packed bus that carries it, and read at a
  non-zero offset per client.** A 26-bit widening changed every `[24:0]` but the arbiter packs
  `c_addr[25*k +: 25]` -- width as arithmetic, not a range. Layers 1 and 2 read shifted; layer 0 and
  the bench's offset-0 reads were fine. An undriven `board` select had also turned base addresses to
  `X`.
- **[Fuuki] One unsigned operand makes the whole comparison unsigned, and a coordinate that can go
  negative wraps.** `line12 < (row_origin + 12'(dst_h))` with `dst_h` unsigned: a row above the
  screen wrapped to ~4092 and matched every scanline; tall sprites repeated down the screen only
  while partly off the top. Make every operand of a signed comparison explicitly signed and wide
  enough.
- **[Seta] Diff the whole core against MAME, not just the CPU.** A CPU-only bench against a
  behavioural ROM ends at the first DIP or protection read. Tracing the whole core and aligning it
  against MAME's trace aligned 93,775 of 100,000 accesses with zero data mismatches, and found a
  protection register and an IRQ ack that fires on a READ (`.rw(ipl1_ack_r, ipl1_ack_w)`, the read
  calling the write). The alignment must skip on BOTH sides (a one-sided window reported 27 of
  20,000, reading as a dead core), and difflib is quadratic: a bounded two-pointer walk with a
  window of a few entries.
- **[Seta] Two correct cores fetch different words: compare as a windowed subsequence with
  duplicates collapsed.** TG68K.C and MAME's 68000 prefetch differently in both directions (extra
  reads, duplicated reads, and *reordering* of nearby prefetches). Give each expected read a
  `consumed` flag satisfiable by any RTL read within a window of ~16; collapse an immediately
  repeated read. A passing run reports large "extra" and "reordered" counts beside zero mismatches;
  those are not warnings. A real divergence puts the RTL on addresses MAME never reads and ends with
  expected reads outstanding.
- **[GX] Compare a CPU's writes per interrupt level, not as one stream.** Once interrupts run, where
  a handler's writes fall among the main program's depends on CPU speed (RTL at 1.11x MAME). Split
  writes by the interrupt mask in SR, compare each level in order; leave the supervisor stack out;
  compare work-RAM stretches sorted by address because MAME's 68020 writes a long to `-(An)` low
  word first and TG68K high first. Registers and I/O stay in strict order.
- **[GX] An out-of-range array index is a simulator-dependent value, and only the disagreement shows
  it.** A vendored SDRAM chip model held `open_row [0:1]` indexed by a two-bit bank; every earlier
  image stayed under 16 MB. Verilator wrapped the index and agreed with itself 900/900; ModelSim
  read X, the row became 0, every sprite row was another row's. When a vendored bench model comes
  from a project with smaller images, check its ranges against this one's.
- **[MS32] `+initreg=r+0` turns an un-evaluated `always @*` into a confident zero.** A vendored V60
  computes `fb_need` in `always @*`, which ModelSim does not run until an input changes; with
  `+initreg=r+0` it read 0, `fb_valid >= fb_need` became `0 >= 0`, and the core decoded an empty
  window as HALT at the reset vector. Four-state it starts X and waits correctly by accident;
  Verilator and Icarus have no time-zero gap. `+initreg` fabricates a value for a combinational
  output not yet computed -- apply it to the files that need it (jotego pipelines), not everything.
  `always_comb` evaluates at time zero by IEEE 1800; `always @*` does not. A combinational signal
  holding a value its equation cannot produce from its inputs is the tell.
- **[BallySente] A bench comparison is valid only against a capture made with the same inputs.**
  A Chicken Shift run with a coin at frame 300 compared against a capture taken without one reported
  449 VRAM bytes and 607 pixels different; the earlier clean result had used matching arguments.
  Write the bench arguments (coin schedule, DIPs, start presses) into the capture's manifest and make
  the comparison script refuse a mismatch.

## Timing closure

- **[BallySente] Ask the timing analyser which path fails; do not reason about it.** A filter
  missed 25 ns by 0.182 ns. The critical path "obviously" ran through the shared multiplier, so
  the operand mux was registered -- still short. Then the mux was given its own cycle -- slack got
  slightly WORSE, -0.288 ns. One `get_timing_paths -setup -npaths 3` named it immediately: the
  failing path was `u_pre -> u`, a 1025-entry `tanh` table the fitter had put in LUTs instead of
  an M10K, nowhere near the multiplier. Two restructures of correct, verified RTL were spent on
  guesses. The query costs seconds:

      create_timing_netlist -model slow -temperature -40 -voltage 1100
      read_sdc <the sdc>; update_timing_netlist
      foreach_in_collection p [get_timing_paths -setup -npaths 3 -detail path_only] {
          post_message -type info [format "SLACK %s FROM %s TO %s" [get_path_info $p -slack]               [get_node_info [get_path_info $p -from] -name]               [get_node_info [get_path_info $p -to] -name]] }

  The corollary: check the fit report's RAM-block count against what the design should infer. A
  table that was meant to be block RAM and landed in logic shows up as an ALM count that looks
  wrong AND as a path that will not close.
### Open the STA summary before believing any hardware-vs-simulation divergence

Quartus reports "Fitter was successful" on a design that grossly fails timing; nothing in the
default flow blocks the `.rbf`. A shipped build had -8.879 ns setup slack and -21,031 ns TNS while
every log line said "0 errors". It appears only in `output_files/<rev>.sta.summary` / `.sta.rpt`.

### Read the Fmax Summary first

`emu|pll|...divclk : 48.74 MHz` against an 85.9 MHz clock is instantly diagnostic.

### Treat "correct in sim, wrong on hardware, reproducible, insensitive to interface tuning" as a timing violation until proven otherwise

Boots but reads wrong data, ~half of golden-ROM comparisons mismatch, reproducible across power
cycles, unaffected by SDRAM_CLK phase, correct in ModelSim -- all also what a timing failure
produces: deterministic because placement is fixed per `.rbf`, phase-independent because the failing
paths are internal, invisible in RTL sim. Interface tuning moves only *external* margins by a
fraction of a period; if it makes no difference at all, the problem is not at the interface.

### [Seta] A clean STA summary is a property of one placement, not of the design

Two builds of the same commit: seed 2 reported every domain positive and broke every game on
hardware (a reset PC with one wrong bit read from SDRAM); seed 7 reported WORSE slack and every set
ran. Nothing in the diff could reach those games, which ruled logic out. The stock `.sdc` constrains
no SDRAM pin, so those paths are fitted on trust. When a build regresses games the diff does not
touch, rebuild the SAME commit at another seed before bisecting source. (Root cause under "Memory
transport", the lane-register entry.)

### Discard measurements taken while the design fails timing

The "~51% of ROM words match" figure and the SDRAM_CLK phase sweep were both taken with the clk_sys
domain failing by 8.9 ns, and both were used to rule the memory interface *out*. Re-run any
measurement that predates a timing fix.

### Get the failing paths with a `quartus_sta` Tcl run

The default `.sta.rpt` has only summaries; the Timing Closure Recommendations panel is HTML-only.

```tcl
project_open <rev> -revision <rev>
create_timing_netlist
set_operating_conditions 7_slow_1100mv_100c   ; # NOT -slow_model / -speed 7
read_sdc
update_timing_netlist
report_timing -setup -npaths 50 -detail summary -from_clock $ck -to_clock $ck -file out.rpt
```

Run `-detail summary` first: 50 rows showed every failing path shared one module, which full detail
would have buried.

### Never let a multicycle constraint touch a posedge-to-negedge path

A constraint matching `{*TG68K:*|*}` swept the wrapper's falling-edge registers in and granted a
half-cycle path two or four full cycles. The Fitter routes it that slowly, the report stays clean,
silicon fails. Two such registers were `waitm` (DTACK sample) and `data_akt_e` (DATA tri-state
gate). Scope a multicycle to a block verified single-edge and `remove_from_collection` every
falling-edge register from BOTH ends.

### Know that the stock MiSTer `.sdc` constrains nothing external

`derive_pll_clocks` + `derive_clock_uncertainty` is the entire file: internal register-to-register
only. Non-empty Unconstrained Paths panels are normal; "timing passed" says nothing about the memory
interface.

### [Seta] A constraint proved in a side project is not in your design

A standalone Quartus project (CPU + sound + SDRAM) reached 96 MHz at +0.011 ns after a TG68K kernel
multicycle. The real project's first compile was -7.954 ns with all thirty worst paths in the
kernel: the side project's `.sdc` had never been copied. Move the constraint, not the conclusion, in
the same commit as the measurement. "All worst paths inside one vendored module" is a missing
constraint, not a design problem.

### [Seta] Relaxing a constraint that is no longer the bottleneck measures WORSE

Kernel multicycle 4 -> 6 (which the enable ratio supports) took slack from -1.816 to -1.969 ns: the
critical path had moved to the sound chip's accumulators and the fitter spent effort where it no
longer mattered. Re-read `report_timing` after every constraint change.

### [Seta] Register a peripheral's CPU interface and give the access an extra cycle; do not constrain over it

The critical path ran register file -> CPU data out -> peripheral address decode -> key-on compare
-> 32-bit accumulator clear in one clock. Registering the whole CPU interface into the peripheral
and spending one more cycle in the access state machine closed it (+0.011 ns); the CPU steps once in
six clocks, so the cycle is free. A peripheral hanging combinationally off the CPU bus is
structural; a multicycle over it is a promise the design does not make.

### [Vamphalf] jt8051 at 56 MHz: two clocks between its own registers, and register what leaves it

jt8051's `DIV AB` is a combinational 8-bit divider: 24 ns at the slow corner against 17.9 ns
(-7.0 ns, TNS -3116). Every register in the core is `else if (cen)`, and its enable (3 in 7 clocks)
is never adjacent, so a two-clock multicycle between its registers is true; with it and the same on
its internal RAM (an explicit `altsyncram` clocked on the same enable, so the claim does not depend
on how an inferred RAM was built), only one path remained: ALU -> `sfr_we` -> the P3 write strobe ->
a register outside the core. The strobe was registered on the enable inside the core rather than the
constraint widened (the Seta entry above): +0.939 ns standalone. The microcode (32K x 48, 1,499
entries used, asynchronous read) synthesises to about 1,200 LUTs, not block RAM.

## CPU cores (TG68K.C, T80, vendored CPUs)

### Budget for the 68k core to be the Fmax-limiting block

Post-fit, Cyclone V speed grade 7: 48.74 MHz, all 50 worst paths inside `TG68KdotC_Kernel`
(`altsyncram` register file and `regfile_rtl_*_bypass`, ~19.6 ns). It has no clock-enable input of
its own to protect you.

### Instantiate `TG68KdotC_Kernel` directly and own the bus interface

`TG68K.vhd` is an async-68000-bus adapter assuming `CLK` *is* the CPU clock, hence its
`falling_edge` registers. The kernel is entirely rising-edge and exposes `clkena_in`;
`mist-devel/plus_too`'s `tg68k.v` is the model (`tg68_clkena = phi1 && (s_state == 7 ||
tg68_busstate == 2'b01)`), stalling the CPU purely by gating the enable. What was tried instead --
an `ext_clkena` gating every process in `TG68K.vhd` -- passed the bench and still did not boot: the
two edges need two enables, and the timing report then needed a multicycle, which is where it turns
dangerous.

### Derive the clock-enable ratio exactly rather than rounding

clk_sys = 14.318181 x 6 = 945/11 MHz and a 68EC020 wants 176/11 MHz: the enable rate is exactly
176/945 and a Bresenham accumulator hits it. /5 is 7.4% fast, /6 is 10.5% slow.

### Do not rely on Quartus resolving an open-collector net the way ModelSim does

`TG68K.vhd` drives `RESET <= '0' WHEN nResetOut='0' ELSE 'Z'` while the wrapper also drives it --
`tri1` models it correctly in simulation. Quartus 17.0 emits `Warning (13048): Converted tri-state
node ... into a selector` whose both-released state sticks low: permanent reset on silicon,
confirmed by a VGA-colour tap. Fix: do not make either side non-tri-state; add a single-driver
`ext_force_run` port ORed in (`cpu1reset <= (RESET OR HALT) OR ext_force_run`). Then check every
consumer: the wrapper's bus FSM used the same raw `RESET`, so fixing the kernel alone left the CPU
out of reset with no bus activity.

### Expose a new port rather than a hierarchical reference for a debug tap

SystemVerilog hierarchical references into VHDL work in ModelSim and fail in Quartus at any depth
(`Error (10207): can't resolve reference`). Add a real output port; unconnected new ports elsewhere
are legal.

### Add explicit zero initializers to vendored VHDL signals before simulating real programs

`TG68K_ALU.vhd`/`TG68KdotC_Kernel.vhd` have many signals with no default; `'X'` propagates from time
0 and can cascade into multi-GB allocation failures once a real program runs. Known upstream
(TobiFlex/TG68K.C#21); 123 signals initialized. Same class as `sdram.sv`'s uninitialized
`state`/`ack0..2`.

### Exercise the ISA extensions you depend on, deliberately

A spike ran 68020-only opcodes (MULU.L, DIVU.L, scaled-index, BFEXTU) before further work. Two
apparent core bugs were testbench mistakes.

### [GX] TG68K.C ignores `MOVEC` to ISP and MSP

The kernel decodes `MOVEC` to `0x804`/`0x803` and stores nothing. A BIOS that hands over with `movec
d0,ISP` leaves the game on the reset SSP; everything matched MAME until the first stack push after
setup. Search the program ROM for `4E7B x804`/`x803` before trusting a stack address. Fixing it in
the kernel: a second assignment to `regfile` makes Quartus build the register file from logic (0
M10K, Fmax 48.97 -> 45.69), and a mux after `regin` lands on the worst path. One write port, address
muxed, value through `regin`'s existing mux: 49.16 MHz, 2 M10K. Re-run the standalone kernel synth
check after any kernel change.

### [MS32] A T80 waiting on SDRAM is a slow Z80: repay the lost clock enables

A real Z80 reads ROM with no wait states; behind the SDRAM bridge the T80 waits a T-state or two per
fetch, and a boot ROM test took 0.1229 s a bank against MAME's 0.0983 -- while the main CPU reads
the Z80's answer at a fixed time. Counting each enable that lands on a read held in T2 and repaying
it with an extra enable at the half period measured 0.098361 s. Measure the sound CPU's *time*
against the reference, not only its correctness.

### Derive `WAIT_n` timing from the CPU's internal T-state behaviour, not external bus inference

A T80 ROM interface built from top-level tracing corrupted a register on one multi-byte opcode with
no visible access to the target address. `T80.vhd` gave the facts: `TState` freezes while `WAIT_n`
is 0 (resampled every cycle), data is captured on the first edge that condition goes true, and
`RD_n`/`MREQ_n` are registered outputs defaulting high so there is always a one-cycle gap between
M-cycles. Fix: a level-tracked `rom_pending` gated by a glitch-free `is_rom_read`, confirmed with
hierarchical access to `MCycle`/`TState`, not by "the test passes now".

### [Seta] Read the interrupt vectors before trusting a board's interrupt config

A board arm was given the family's usual scanline-timer config; its machine config has none (vblank
asserts one level until an ack write, a uPD71054 another). The ROM said what the wrong config
risked: the level-1 autovector shares its target with bus error and illegal instruction, and that
target is the reset entry. Not proven that the extra IRQ caused the restart -- a scan found no
instruction lowering the mask to 0. Dump the vector table before deciding a board's interrupts; an
ack address that is also an input port must acknowledge on writes only.

### [Vamphalf] `irqN_line_hold` names MAME's input line N, not the CPU's interrupt N

`set_vblank_int(..., irq1_line_hold)` asserts input line 1. For the Hyperstone E1 that is
`INPUT_INT2` (`e132xs.h`: `INPUT_INT1 = 0`). The core wired vblank to INT1 from the name; the
boot set FCR to 0xdd7fffff (INT1 inhibited, INT2 enabled) and the game sat in its idle loop at
the PC MAME's speed-up handler names, waiting for a flag the vblank handler sets. Read the CPU's
`INPUT_*` constants, and the mask register the game writes, before naming an interrupt.

## Quartus synthesis gotchas (not visible in ModelSim)

- **Non-blocking assignments to block-local (`automatic`) variables are rejected**, even with
  `static`: `Error (10959)`. Move to module scope, re-run the regression.
- **Multi-driver conflicts on a shared tri-state net are a hard error** (`Error (13076)`), surfacing
  at a deeper signal than the one touched. Use the separate-signal OR pattern.
- **A non-power-of-2 modulo synthesizes as a slow iterative divider.** `sram_data % 16'd768` was the
  worst path in the design (`Mod0|auto_generated|divider`), not a suspect from a read-through. A
  conditional-subtraction chain kept one-cycle timing. Read `report_timing`'s worst path rather than
  guessing the module.
- **Negative PLL phase shifts are not legal for every PLL configuration.** `-3000ps` rejected; use
  `period - abs(shift)` rounded to the step Quartus names in its error.
- **Driving a dual-port RAM's second read port can silently REPLICATE the whole array.** An M10K has
  one write and one read per physical port; two independent reads plus a write duplicates the
  memory: a 128 KB RAM reporting 2,097,152 bits, `Error (170048): needs more than 553`. The second
  port had been tied to a constant and optimized away, so wiring it read as "using a port that was
  there". Share the existing port when the consumers cannot collide. [MS32] The dual-clock form:
  port A on the CPU clock in one always block and port B on clk_sys in another inferred two copies
  of every video RAM; an explicit `altsyncram` in `BIDIR_DUAL_PORT` with two clocks and byte enables
  is one array.
- **[Seta] A true dual-port RAM must be ONE always block with both ports in it.** Two `always_ff`
  blocks writing the same array builds it from registers and says nothing: an 8 KB register file
  took the design to 122,886 combinational nodes against 83,820 (`Error (170011)`), which reads as
  "too big". Template: both `if (we_a) mem[addr_a] <= din_a; q_a <= mem[addr_a];` and the B pair in
  one block. Only a fit says whether what you wrote can exist.
- **[Seta] An inferred RAM must have a power-of-two depth.** `pal [0:3071]` was not inferred, no
  warning; 3072 words in logic, `Error (170012): requires 6497 LABs`. The give-away: 55% over on a
  design at 59%, from a change adding 1024 words. A RAM-block count that DROPS while a memory grows
  is the symptom.
- **[GX] Put every inferred memory in a one-write, one-read template module of its own.** A packed
  `[3:0][7:0]` VRAM with byte enables and two read ports: "uninferred due to asynchronous read
  logic" (276007). Split into byte lanes: every lane duplicated for the second reader. Line buffers
  declared inside a `generate` loop driving an unpacked output array: ~24K ALMs, 46K registers, no
  message naming them. What worked: a textbook simple-dual-port module (`gx_sdpram.sv`) instanced
  per memory, one read port shared. A standalone synth harness per block found all three; in the
  full design they would have been a failed fit pointing at nothing.
- **[MS32] Past about 90% of M10K, count blocks, not bits.** An M10K is 1024 x 10 (or 256 x 40, 8192
  x 1), so a 32,768 x 16 RAM is 64 blocks however many bits it holds. 82% of bits and still over 553
  blocks.
- **A design can be BRAM-bound while logic sits at 40%.** Budget in M10K blocks. No memory packs at
  100%; ~95% of bits cannot be fixed by repacking, only by removing memory. Confirm where the bits
  went before restructuring.
- **`set_instance_assignment -name RAMSTYLE` is rejected by the `.qsf` parser in 17.0** (`Error
  (125048)`, aborts project open). Use `(* ramstyle = "..." *)`.
- **[GX] Quartus 17 rejects `for (genvar i = ...)`** (`Error (10170)`); declare `genvar i;` before
  the `generate`.
- **`quartus_map` alone is a fast pre-check** for whether a change elaborates.
- **[Vamphalf] Do not write an array at a variable index and then change the index in the same
  block, twice in one clock.** The E1's register-write queue was pushed by a task doing
  `wq_v[wq_cnt] = v; wq_cnt = wq_cnt + 1;`, called twice in one clock by a CALL (return address,
  SR) and by the reset state (L0, L1). Verilator ordered it right; on the board the first push
  never arrived and the second did, so the first RET jumped to 0 and the screen stayed black.
  Quartus had also made `wq_v` a one-write-port `altsyncram`; `ramstyle "logic"` removed the RAM
  and not the fault. Writing each entry under a constant index (a `case` on the count) did. Every
  simulation was right throughout, including a top-level bench with the real download and random
  power-up state. What found it in one build: an architectural trace on the board (each retirement,
  register write and bus transfer, `rtl/debug/vh_trace.sv`) compared per category with the same
  RTL's trace in the bench (`scripts/trace_compare.py`). Before that, eleven builds each probed one
  guess. Build the trace first when a core runs in simulation and not on the board; and read the
  map report's "Parameter Settings for Inferred Entity Instance" list for small arrays that should
  not be RAM.
- **[Vamphalf] Synchronise an ISSP source before it drives a reset.** The probe's hold bit comes
  from the JTAG side; released asynchronously into a 56 MHz core, it restarted the CPU and its memory
  unit in different clocks and the first records after it were an exception frame, not the reset.

## Debug instrumentation: how not to fool yourself

- **Never reset a debug counter with the reset you are investigating.** Two `0x000000` readings were
  reported as findings before noticing the counters cleared on `reset`, asserted for the whole
  window. Declare with `= 0` and no reset; Quartus powers registers to zero.
- **Pair every "bad event" counter with a "total events" counter.** A zero can mean "did not happen"
  or "was never allowed to count".
- **Sample registered signals, not combinational ones, and prove the probe on a known-good
  configuration first.** A tap on combinational `cpu_data` showed byte-skewed latching -- compelling
  and false; the same probe in a booting simulation showed the same skew. If a new probe reports a
  fault on a known-good setup, the probe is the fault.
- **Never let a probe's step size share a factor with the period you are measuring.** A tracer
  skipping `window * 256` events returned byte-identical captures at every window, consistent with
  both a CPU resetting every 256 reads and a path aliasing every 256 words. Step is now `window *
  8191`. When a probe gives the same answer at every setting, suspect the step.
- **Capture the full address.** Packing `addr[7:0]` into a pixel made a linear sweep look like
  dropped high bits. If address and data do not fit, use two buffers strobed by the same event.
- **[Fuuki] The framework applies the user's gamma LUT to the core's RGB before screenshots; force
  it off under a debug overlay.** Trace pixels came back through a monotonic per-channel curve
  (`0x40 -> 0x38`), looking like SDRAM lane corruption; cause was `MiSTer.ini`'s `preset_default`
  setting `gamma=...gamma_110.txt`. Clear `gamma_bus[19]` while the overlay is on. Draw each value
  and its bitwise inverse in alternating bands: they must XOR to `0xFFFFFF`, so any transform in the
  capture path is detected.
- **[Fuuki] "The game plainly means no interrupt" is a guess; what MAME does is the spec.** A raster
  register parked at `0xFFFE` was read as "disable"; the game's main loop waits on a flag only that
  handler sets. MAME's `time_until_pos()` wraps modulo the *driver's* screen height and fires every
  frame. Found by one JTAG read of `last_rom_addr` alternating over a 4-word `btst/beq` loop. Follow
  the framework's arithmetic with the framework's numbers: reducing by the RTL's 262 lines put it
  mid-picture; the driver's 256 puts it in vblank.
- **[Fuuki] A debug gate that keys off the load path dies when the load path changes.** Trace
  sources gated on `dl_done` (set by `ioctl_wr` with index 0) went dark when the fast DDR load
  bypassed ioctl entirely; every dump was 256 zeros and the readout reported no problem. When a
  transport is replaced, grep for every flag derived from the old one.
- **[Fuuki] `write_source_data -value` takes a binary string; pass `-value_in_hex`.** `-value 8`
  printed "set to 8" and read back `00`; every page select issued that way was a no-op while `clear`
  worked ("1" and "0" are valid binary). Read every source back after writing.
- **[Fuuki] When reading finds nothing, tag the data and let the hardware say where it went.** A
  one-line offset was argued over three pipeline stages; tagging each line buffer with the row its
  engine set out to render and subtracting the display line answered it in one read.
- **VGA-colour-override builds answer yes/no hardware questions without a logic analyzer.** Override
  `VGA_R/G/B` with a solid colour gated by an internal signal; extend to 3- or 4-colour readouts via
  sticky latches. Remove all `dbg_*` wiring once fixed.
- **JTAG ISSP pokes test a hypothesis on live hardware without a rebuild.** With the CPU paused,
  single VRAM words were written and the screen read directly; that established the chained N/N+1
  dependency behind the tilemap handshake bug before any RTL changed.
- **Do not blind-enable an interrupt path you have no way to verify.** Enabling a sound-chip timer
  IRQ to the Z80 took its fetch counter to zero -- a lockup, worse than the silence it was meant to
  fix. Expose `halt_n`/PC in the same build.
- **A sound CPU that programs the chip once and then goes quiet is an interrupt-path symptom.** 46
  register writes at launch, zero over a later window: the init burst runs from boot code; music is
  sequenced by the chip's timer interrupt.

## Driving MAME as a reference generator (Lua)

- **[BallySente] A sound reference captured without starting the game is the SOUND BOARD's boot
  routine, not the game's.** Four Bally/Sente cartridges were captured for 10 s each and replayed
  against the model, and all four produced identical numbers to four significant figures. That
  looked like a bug in the replay; it was not. The 6VB audio board runs its own ROM, so its boot
  and self-calibration sequence is byte-identical across cartridges -- the first 3 s were the same
  66,882 control writes in every set, and MAME's own audio for four different games agreed to
  -112 dB over the whole 10 s, because none of them had reached game audio. Insert a coin and
  press Start (the `wtiming.lua` field pattern), then compare from after the attract sequence.
  The check that catches this cheaply: diff the REFERENCE captures against each other first. If
  two different games give the same reference, the stimulus is not the game.
- **[Fuuki] [GX] Keep every Lua subscription in a GLOBAL.** `add_machine_frame_notifier` and
  `install_write_tap` return subscription objects; dropped, the GC reclaims them and the callback
  silently stops firing, exit 0. A `local subs = {}` at chunk scope is not enough: chunk-locals
  become collectable when the chunk returns, before the first frame. Measured: `local`, the notifier
  fired exactly 100 times; global, past 400 to the end. Even a `pcall` wrapper reports nothing,
  because there is no error; a heartbeat counter written from inside the notifier found it.
- **[Seta] An error inside a write tap is SWALLOWED.** A callback calling `scr:vpos()` (nil in
  0.286's binding) raised every time and the log held only its header: 459 hits, 0 logged. Wrap
  every callback in `pcall`, keep a hits counter beside a logged counter, write both plus the first
  error. Derive what the binding lacks: `line_period = time_until_pos(1) - time_until_pos(0)`, `line
  = (frame_period - time_until_pos(0)) / line_period`.
- **[Fuuki] Check `mame.ini` for `debug 1` before automating.** The debugger halts at startup; the
  autoboot script still loads and prints. Pass `-nodebug`; same for `window 1` headless.
- **[BallySente] Point `-autoboot_script` at `run.lua`, never at the script itself.** The skill
  shipped `run.lua` -- the wrapper whose whole purpose is to turn a Lua fault into a file the
  Python side reads back -- but `mame_capture.py`'s `mame_cmd()` passed the target script
  directly, so nothing ever used it. A bad range in `install_write_tap` then surfaced as a modal
  dialog on the user's desktop while the runner reported only "no trace written": the failure was
  visible to the human and invisible to the tooling. Two sibling cores (Seta, MS32) already routed
  through `run.lua` and read `lua_error.txt` back; the skill's copy had regressed. Wire it in
  `mame_cmd()` and pass `CORE_SCRIPT`, and call `check_lua_error(out)` before blaming the capture.
- **[BallySente] `install_write_tap` must stay inside the space's global address mask.** An I/O
  space declared with `map.global_mask(0xff)` rejects `install_write_tap(0, 0xffff)` outright --
  "end address is outside of the global address mask ff, did you mean ff?". Read the driver's
  `address_map` for a `global_mask` before choosing the range.
- **[BallySente] The MAME BINARY must be the version of the MAME SOURCE you read.** Notes cited
  `balsente.cpp` at a source tree tagged 0.289 while the runner drove an `arcade64.exe` 0.286
  (ARCADE, a fork) picked up from a sibling core's `mister.env` -- and the installed vanilla
  `mame.exe` was 0.285. For a device MAME had just rewritten, that is not a detail: 18 commits
  separate 0.285 from 0.289 on `cem3394.cpp` and the `va_*` primitives, so an audio comparison
  against either binary would have been a port of the new model diffed against the old model's
  output, disagreeing for reasons that mean nothing. Check `<exe> -version` against
  `git -C $MAME_SRC describe --tags` at the start of any work that leans on a specific device, and
  prefer vanilla MAME over a fork unless the fork is the reason for the work.
- **[Fuuki] Snapshots work under `-video none`** and land one level deeper than the directory given;
  search recursively.
- **[Fuuki] Read dumps through the CPU's own address space**:
  `devices[":maincpu"].spaces["program"]:read_u16(addr)`, device handlers included -- what the RTL
  must match.
- **[Fuuki] [Seta] Where a value is compared against a raster position, the height that matters is
  the driver's declared one, not the RTL's.** Both boards declare 256; the RTL's frame is ~262.
  `frame_period / line_period` from Lua gives 256.000 exactly.
- **[Fuuki] A vendored core that is silent in simulation may only be uninitialised.** jotego's jtopl
  and jt12 leave envelope pipelines without reset; hardware powers up zero, ModelSim leaves X, and X
  through an envelope generator takes every write and never sounds. `$isunknown` on the output named
  it; `+initreg=r+0 +initmem=r+0` on those files, not an edit.
- **[Fuuki] A chip select from an address decode alone takes memory writes too.** `WR_n` asserts for
  memory and I/O alike; qualify with `IORQ_n`.
- **[MS32] Dump a double-buffered RAM at the moment the driver copies it, not at the frame
  notifier.** The driver copies sprite RAM at vblank START; the notifier fires at frame END after
  the handler has written the next list, so the dump is one frame ahead of the screenshot. Static
  title screens hid it; animated frames showed 1.7% and 0.15% wrong, every one a sprite. Rendering
  frame N with frame N-1's RAM matched to the pixel. `emu.wait` needs a coroutine an autoboot script
  lacks, so the capture arms a write tap at the end of frame N-1 and dumps on its FIRST hit.
  Whenever a driver keeps its own copy, take the reference when the copy is.
- **[MS32] MAME's native snapshot of a ROT270 set is landscape and turned 180 degrees.** `-snapview
  native` gave 320x224; the model matched at 60% and 0.3% until turned 180 (not mirrored). Reading
  `render.cpp` in a 0.289 tree predicts portrait; the 0.286 binary produces landscape. Compare under
  the four flips, record which matches, pin it in the tool from the capture's `orientation` line,
  refuse any orientation not measured.
- **[Seta] Check flip screen against the rotation, not against the emulator.** MAME's own flip is
  wrong for some drivers (its tilemap code now mirrors about the visible area; the driver's `-512`
  was written against the bitmap). The reference is the unflipped frame rotated 180, checkable from
  captures of the same frame with the DIP off and on. Flip also moves parked sprites into the
  picture (unused entries at one Y land on the top visible lines), which a sprite bench with no
  budget cannot show.
- **[GX] MAME's `nvram/<set>/eeprom` for a 16-bit serial EEPROM is little-endian words.** MAME's
  memory dumped as it is on x86. A bench loading it big-endian ran identically to MAME for 700
  frames until the game's first settings read.
- **[Vamphalf] The debugger's `trace` action and `tracelog` from a tap write to the VISIBLE CPU's
  trace file, not to the CPU the tap belongs to.** Tracing a CPU that is not the first (the QS1000's
  8052, `:qs1000:cpu`) with `trace file,<cpu>,noloop,{tracelog ...}` produced only the disassembly
  lines: the action ran, its output went to the main CPU, which has no trace. `focus <cpu>` does not
  change the visible CPU while the machine runs; the Lua property `manager.machine.debugger.visible_cpu
  = cpu` does. Check that the first record has the register fields before a long run.
- **[Vamphalf] Print `tracelog` arguments with `0x`.** They are debugger expressions, and a value
  that is also a symbol is read as the symbol: on the 8052 an offset or byte of 0x0a printed as 0
  (`a` = ACC), 0x0b as B's value. `%x` of 10 is `a`; `%#x` is `0xa`. It lost no row, it corrupted the
  address (MOVX writes at 0x000a and 0x000b logged at 0), which showed up as the first
  mismatch of the RTL bench at the 472nd instruction.
- **[Vamphalf] A driver that does not set `VIDEO_UPDATE_AFTER_VBLANK` is drawn in `vblank_begin`, and the
  Lua frame notifier runs in the same call, before the vblank IRQ.** The RAM dumped in the notifier is
  therefore the RAM the frame was drawn from (`emu/screen.cpp:1149`); 342 of 342 frames per set matched to
  the pixel with no frame shift. The MS32 entry above is the opposite case. Read the driver's video
  attributes before deciding where to dump.
- **[Vamphalf] A driver that changes the visible area inside `screen_update` draws each frame with the area
  of the previous one, and leaves rows outside the clip as they were.** Flip toggled in a capture: 4 lines
  (1280 px) of the first frame after each toggle were wrong against a model that fills the whole visible
  area; the stale rows were exactly what the first flipped update had drawn into rows 16..19. Zero after
  the model kept the bitmap between frames and used the previous update's area as the clip. Record
  the flip state of the previous frame in the capture manifest; a capture taken in the notifier that
  applies a change shows the picture from before it.
- **[Vamphalf] A single coin pulse of 1, 3, 20 or 60 frames left CREDIT 0 in both sets, although the
  game read the coin bit low on 0x90 for the whole pulse; coin pulses repeated every 97 frames from
  frame 400 gave credit 9 by frame 1000.** Cause not looked into. A play stimulus must be checked by
  looking at the credit counter on a snapshot, not by the input having been read.
- **[Vamphalf] `memory.regions[":gfx"]` has `read_u8/u16/u32/u64` and no `read_range`; `read_u64` returns
  "integer value will be misrepresented in lua" and aborts the callback.** Dump a region with `read_u32` and
  `string.pack("<I4")` and check a few addresses against `read_u8`. The program-space dumps use
  `read_u32` per word and compare their first 64 bytes against `read_u8`.
- **[Vamphalf] A ROT270 set's `-snapview native` snapshot is turned 180 degrees from the bitmap; a ROT90
  set's is not.** `misncrft` matched unturned, `wivernwg` after `rot180`; found by trying the four
  mirrors on the first frame, then pinned (`render_model.py compare`). Same finding as the MS32 entry
  above, with a different rotation.
- **[Vamphalf] A 32-bit-bus set needs full-width I/O writes from Lua: `ios:write_u16(0x800, 1)` left the flip
  handler seeing data 0.** The CPU's own write is 32 bits wide (tap mask ffffffff) and the handler is
  `umask32(0x0000ffff)`; the cause was not isolated (a 16-bit write most likely lands in the other half of the 32-bit lane). Copy the width and mask of the
  game's own write from a tap before poking.
- **[Vamphalf] Keep a reference to every tap: an unreferenced `install_*_tap` handler is garbage-collected
  and the tap stops without a message.** A tap held in a `local` of the script's main chunk logged I/O for
  about 100 frames and then nothing, inputs included, which the game reads every frame. The capture's
  conclusion ("no sound commands during play") was an artefact. A tap the frame callback refers to (to
  remove it at the end) survived. Hold taps in globals, and check that a capture has accesses up to its
  last frame.
- **[Vamphalf] A `PORT_CUSTOM_MEMBER` field declared `IP_ACTIVE_LOW` reaches the bus inverted.**
  `ioport_port::read()` merges the callbacks' values and then XORs the whole port with its default
  (`src/emu/ioport.cpp:1595`), custom fields included, so a callback's "7 = no hit" reads as 0. `boonggab`'s
  photo-sensor field was transcribed from the callback's table and idled at the strongest hit; the I/O log
  settled it (P1_P2 0xc7ff idle, 0xcfff with the weakest). Take a custom field's encoding from a tap of the
  port, not from the callback.

## Hardware bring-up (MiSTer / DE10-nano)

- **The SDRAM pinout has an authoritative in-repo reference.** The `.qsf` does `source sys/sys.tcl`;
  cross-check `output_files/<rev>.pin`. The `.qsf` also *restates* every location assignment after
  the `source` line because the IDE re-saved the project, so a future `sys.tcl` update would be
  silently overridden.
- **Audit an inherited `.srf`.** One hid 15705 ("Ignored locations or region assignments"), which
  could mask a dropped pin, and referenced a file that does not exist.
- **Fitter warnings 176250/176251 (invalid fast I/O register assignments) are usually benign**; the
  Ignored Assignments panel names which. Confirm by counting register-packing entries on `SDRAM_DQ`
  (16/16 packed) -- and see the lane-register entry for the case where they are not.
- **The SDRAM_CLK phase shift is legitimate but a poor first suspect.** `-3 ns` is the MiSTer
  convention, expressed as the positive equivalent because `altera_pll` rejects negatives. Sweeping
  to `0 ps` gave byte-identical results, which said the fault was not at the interface. Revert
  diagnostic PLL values immediately.
- **`/dev/fb0` is the ARM-side OSD surface, not the FPGA's video.** Use the screenshot API, which
  captures scaler-composited output.
- **MiSTer Remote API** (wizzomafizzo/mrext, port 8182): read its Go source. `POST /api/launch
  {"path": ...}` writes `load_core` to MiSTer's command device. `POST /api/screenshots` returns
  nothing useful; poll `/media/fat/screenshots/<core>/` for a new file, often seconds late.
- **An automated deploy-then-launch needs an explicit settle gap.** Back-to-back deploy then launch
  hit a real race (the `.rbf` not flushed) that never appeared manually; `sync` plus a short sleep.
  When a race is suspected in a tool, re-run the manual sequence before assuming the binary is
  stale.
- **`plink.exe`/`pscp.exe` are the non-interactive SSH/SCP path on Windows**: `echo y | plink.exe
  -ssh -pw <pw> user@host "cmd"`.
- **MSYS/Git-Bash silently mangles POSIX-looking arguments** (`/media/fat/...`) into Windows paths
  for non-MSYS programs. `MSYS_NO_PATHCONV=1`.


- **[MS32] MAME is not the oracle for sound timing.** A sample's difference in when a voice starts
  is within the model's own error; deploy and judge by ear before chasing it in RTL.
- **[Fuuki] A reference frame that looks wrong may be the wrong frame.** Before treating a
  screenshot mismatch as a fault, check when the grab was taken on each side; the same scene one
  frame apart is not a difference in the hardware.
- **[Seta] Drive the plain `mame.exe`, not a fork build.** A fork (`arcade64.exe` and the like) is
  not the driver reference the notes cite and its Lua surface can differ.

## Tooling and workflow (Quartus, ModelSim, Verilator, and the shell around them)

- **Working directory does not reliably persist into backgrounded commands.** `cd <project> &&
  <tool>` in one line, or put the `cd` in the Tcl. Symptoms: `Error (23018): Tcl Script File ... not
  found`, `Error (12007): Top-level design entity ... is undefined`.
- **`quartus_sta`/`quartus_map`/`quartus_sh` are not on `PATH`**; full path. With two installs, the
  wrong one's post-fit database will not match.
- **Never run Quartus wrapped in `nohup ... &`.** The call reports completed immediately and the
  process runs untracked.
- **Never switch git branches while a Quartus process is reading the tree.** It silently kills the
  run, leaving a truncated log that looks like a crash.
- **[MS32] Do not edit a script or source file while a run that reads it is in flight.** bash reads
  a script incrementally; an edited running script died with a syntax error at a line well-formed in
  both versions. Same for a bench edited between compile and run, and a `.qsf` during a flow. Files
  a background run reads are frozen until it reports.
- **Never leave duplicate tool instances on the same project.** Overlapping `quartus_map` corrupts
  the log; two `vsim` on one bench write the same file and killing one takes the other (`Fatal: vish
  lost connection`).
- **Sweep for orphaned `vsimk.exe` kernels at the start of any simulation session.** Killed runs
  leave kernels at 100% CPU (six found once, ~90,000 CPU-seconds); working set drops to ~45 MB, so
  size is not liveness. `Get-Process vsim,vsimk | Select-Object Id,CPU,WorkingSet64,StartTime`;
  `Stop-Process -Force` (`taskkill` fails). Left alone they make every later run look pathologically
  slow.
- **The ModelSim `work` library lives at the repo root**, mapped by each bench directory's
  `modelsim.ini`; run `vsim` from the bench directory; recompile only changed files.
- **[Fuuki] A bench that prints nothing has usually not run.** A compile killed by a timeout leaves
  `work/_lock`, on which every later `vlog`/`vcom` waits silently; three "silent chip"
  investigations were a lock. Recreate the library every run.
- **[Fuuki] Build from a snapshot, not from the tree you are editing.** A staged-build script was
  judged optional and left unported; every edit then waited on a full compile, a build died
  mid-Fitter with an edit in flight, and a `.qsf` hand-edit was silently reverted by Quartus
  re-saving the project. A worktree at `build/` costs one script.
- **[Seta] `bash` on a Windows box may be WSL's, which is a different operating system.** A sweep
  spawned `bash`; all thirteen sets failed identically ("no result", reading as a systematic RTL
  fault) while the same command by hand passed. `shutil.which` reported Git's bash; the exec got
  WSL's, which cannot run Windows ModelSim. Name the shell explicitly and refuse WSL. Read the
  *first* failing command's stderr before believing a pattern: it said `/c/...vlib.exe: No such
  file`.
- **[Seta] Pin shell scripts to LF in `.gitattributes`.** With `core.autocrlf`, `git reset --hard`
  gave every `.sh` CRLF; `set -euo pipefail\r` dies on line one -- interactively tolerated, fatal
  from a wrapper. `*.sh text eol=lf`, same for `.tcl` and `.lua`. `git add --renormalize` fixes the
  index only.
- **[MS32] `Path.read_text()`/`write_text()` without `encoding=` corrupts UTF-8 on Windows.**
  Default cp1252; `×` and `°` became single bytes and a file with an undecodable byte refused to
  load, so half an edit landed. Every repo-file `open` names `encoding="utf-8"`; a multi-file patch
  script checks all files in first.
- **[GX] Never read a file inside the argument list of the call that truncates it.** `open(p,
  "w").write(open(p).read().replace(a, b))` opens for write first and reads the empty file; it
  emptied a 736-line document, and the truncation was committed so `git status` was clean while two
  later commits described changes to nothing. A clean `git status` says the commit matches the tree,
  not that either is correct. Check `wc -l` after a rewrite; make edit scripts assert on what they
  expect to find.
- **[GX] MSYS2's GCC 16.2.0 cannot link `-Os` C++ that moves a `std::string`.** A pacman upgrade
  broke every Verilator link (undefined `basic_string(basic_string&&)` from `verilated.o`); `-O2`
  links. Pass `-MAKEFLAGS OPT_GLOBAL=-O2`. After any MSYS2 upgrade, rebuild one bench from a clean
  `obj_verilator/`.
- **[GX] A comment line beginning "Verilator" is a Verilator pragma.** `// Verilator reaches it ...`
  fails with `BADVLTPRAGMA`. Three times in one bench.
- **[GX] A Verilator snapshot written on Windows needs binary mode.** `VerilatedSave` uses `open()`
  in text mode; every `0x0A` became `0D 0A` and restore failed with "wrong end-of-file signature".
  `_fmode = _O_BINARY` at the top of `main()`.
- **[HyperNG64] A fine-grained GitHub token cannot run `gh repo create --template`.** It fails
  with "Resource not accessible by personal access token (cloneTemplateRepository)" even with
  Administration write; the GraphQL mutation behind it is refused. The REST endpoint
  `POST repos/<owner>/<template>/generate` works with the same token. `new_core.py` uses it.
