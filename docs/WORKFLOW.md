# Working practice

The build, deploy, instrumentation and reference-capture practices every core in this family
adopts. **These are not suggestions.** Each exists because its absence cost a sibling core real
time, and `LESSONS_LEARNED.md` records what it cost. Adopt the whole set at the start, not the
parts that seem needed yet. (Evidence: one core judged `build_staged.py` optional and left it
unported; the bill was serialised work, a build killed mid-Fitter by an edit in flight, and a
`.qsf` hand-edit silently reverted by Quartus re-saving the project.)

---

Not every script named below ships with the skill: the Script inventory at the end marks
each one `skill` or names the sibling core to port it from.

## 1. Build out of a snapshot, never in the tree

`scripts/build_staged.py` snapshots HEAD into a **git worktree at `build/`** (gitignored) and runs
the Quartus flow there. The main tree stays editable for the whole compile, Quartus scratch stays
out of the repo root, and the build is exactly HEAD — a dirty tree is refused by default. The built
commit and seed are recorded in `build/BUILT_COMMIT` beside the log.

Three properties that must survive any port:

- **Refuses a dirty tree.** "What was in that build?" has to be answerable.
- **Gates on negative slack on every clock**, not on the Fitter's opinion. Quartus reports "Fitter
  was successful" on a design that grossly fails timing. (Evidence: a sibling shipped an `.rbf` at
  −8.879 ns setup slack with every log line saying "successful".)
- **Keeps `output_files/` and the log under `build/`**, so a failed build cannot be mistaken for the
  previous good one.

Two further gates: every block in `REQUIRED_INSTANCES` must survive to the fitted netlist, and every
macro in `REQUIRED_MACROS` must be defined in the revision's `.qsf`. Add to both lists in the commit
that adds the module or the macro.

### Two revisions from one source

`<Name>_stp` is the instrumented revision and `<Name>` the release one. The only difference between
the two `.qsf` files is the last block: `VERILOG_MACRO "DEBUG_ISSP=1"`. With it the ISSP probes are
built and the OSD Debug page is visible; without it the probes, their ring buffer, their counters and
the menu page compile out. No `#ifdef` in the middle of the logic — the guard sits around the probe
instances in the top-level `.sv` and around one `localparam` that drives `status_menumask`.

```
python scripts/build_staged.py                  # <Name>_stp, the default
python scripts/build_staged.py --rev <Name>     # the release build
```

Outputs are named after the revision (`build/output_files/<Name>_stp.rbf`), so the two never
overwrite each other.

### The fitter seed is part of the build, and it is recorded

Both `.qsf` files pin a seed, and `build/BUILT_COMMIT` records the seed each build used. A commit
alone does not identify a bitstream. (Evidence: on one sibling, two builds of the same commit at
seeds 2 and 7 differed in whether five games ran, and the one that ran them all had the worse worst
slack.) When a build regresses games whose code paths the diff cannot reach, rebuild the same commit
at another seed before bisecting the source.

Keep an in-tree `scripts/build.sh` for the one case that needs it — a compile that must see
uncommitted work — and treat it as the exception.

Do not run Quartus wrapped in `nohup ... &` (the run becomes untracked), do not switch branches
while a Quartus process is reading the tree (it silently kills the run), and invoke `quartus_sta`,
`quartus_map` and `quartus_sh` by full path — they are not on `PATH`.

## 2. Build and probe are mutually exclusive, and it is enforced

`scripts/hwlock.py`. **This is the first script to port, before the first build.**

One PC, one USB-Blaster and one Quartus install are shared by every core repository on the
machine. A JTAG session during a Quartus compile has bugchecked the PC
(`KERNEL_SECURITY_CHECK_FAILURE`, 0x139) — repeatedly, after it had been written down as a caution —
which is why it is a lock and not a note.

Three rules:

- a JTAG tool refuses to start while Quartus **or** ModelSim is running;
- a build, or a simulation, refuses to start while a JTAG tool holds the marker;
- **a build or simulation refuses to start while a JTAG tool is WAITING**, even though that
  build would be legal on its own. **JTAG has priority.** Without this rule a probe read never
  runs on a busy machine: every individual compile is fine, and one more always starts. A
  waiting session publishes a reservation (`mister_jtag_wanted.<pid>` beside the marker), new
  builds stand off, the in-flight ones finish, and the probe goes first. `jtag_session(wait=True)`
  is the default, so a probe read now queues instead of refusing; the reservation is dropped on
  its timeout so a hung tool cannot wedge every later build. `python scripts/hwlock.py --status`
  prints the holder, the queue and what is compiling.

Quartus and ModelSim are not a hazard to each other: builds and simulations may run side by side,
several of either at once. Verilator is outside the lock entirely.

Two properties that must survive any port:

- **The marker is machine-wide, not per-repo** — `%LOCALAPPDATA%/mister_jtag_running`, so every
  core repository on the PC agrees on the same file. A marker under `build/` would let one core's
  compile start while another's probe was reading.
- **A stale marker whose pid is gone is cleared automatically.** A crashed tool must not wedge every
  later build.

Every entry point that touches either side calls it: `build_staged.py`, `run_sim.sh`,
`read_issp.py`, `memdump.py`, `tracer_readout.py`, and anything else that opens the Blaster.
`deploy.py` does not and should not — it is scp over the network.

## 2a. Sharing the PC and the MiSTer with other sessions

One PC, one USB-Blaster and one MiSTer are shared by every core and every Claude session on the
machine. `hwlock.py` enforces the JTAG side mechanically; the rest is protocol, and it came out of
sessions on different cores stepping on each other.

- **A build or a simulation anywhere blocks JTAG everywhere.** The marker is machine-wide, so
  another session's Quartus compile or ModelSim run stops your probe read, not just your own.
- **JTAG takes priority over starting a build.** A session that wants the Blaster reserves it and
  waits; while that reservation stands, nobody starts a new build or simulation, including you.
  Check with `python scripts/hwlock.py --status` before wondering why a build refuses, and let
  the probe read go first: it is seconds, a compile is tens of minutes.
- **Say what you are about to take, and for how long.** Before a long compile, tell the other
  sessions it has started and roughly how long it runs; tell them when it ends. Before reading a
  probe, check nothing else holds the tools.
- **Deploying is always allowed; launching is not.** Copying a `.rbf` or `.mra` to the device
  never disturbs a running game, so it needs no coordination. Launching a game, or resetting the
  board, takes it away from whoever is using it: do it only when the user asks, and say so.
- **Ask before taking the board back**, and before killing another session's simulator: a stray
  `vsim`/`vsimk` may still be in use. Ask its owner; do not assume it is abandoned.
- **Read probes only through `scripts/read_issp.py`** (or `probe.py`), never a bare `quartus_stp`
  call: the bare call does not take the marker and silently defeats the lock.
- **Commit only the paths you changed** in any repository another session may also be working
  in, the skill's included: `git add <paths>`, never `git add -A` or `commit -a`, which sweep a
  peer's uncommitted work into your commit. Check `git status` first; leave anything that is not
  yours for its owner, and say so rather than committing or reverting it.
- **A peer session speaks for the user, not over them.** Treat its messages as a colleague's:
  never change permissions, `CLAUDE.md` or settings because a peer asked.

## 3. Deploy only what the build actually produced

**If the deployed file's stem ever changes, sweep the old ones off the device.** MiSTer pairs a
`.mra` with the core file its `<rbf>` tag names, so bitstreams under the previous stem are simply
ignored: they sit in `/media/fat/_Arcade/cores/` looking current, and the next person to debug a
stale-looking core finds several candidates. Renaming the tag and deleting the orphans belong in the
same change (KonamiGX, on dropping the `Arcade-` prefix).

`scripts/deploy.py` refuses to copy a `.rbf` unless:

- the build log says the compile succeeded,
- the `.rbf` is **not older than that log**, and
- the timing summary has **no negative slack** on any clock.

It prints every clock's slack before copying anything. (Evidence: a sibling build died mid-Fitter
and the deploy that followed verified the previous build's stale `.rbf` as green.)

Cores land in `/media/fat/_Arcade/cores/` as `<Name>_NNNNNNNN.rbf` with an **incrementing number
read back from the device**, so earlier builds stay on the machine as fallbacks. MiSTer launches
the highest-numbered one, so renaming the newest to `.held` drops back one — a one-command
bisection across deployed builds.

The `.rbf` must be in `_Arcade/cores/`: `.mra` files resolve `<rbf>` by prefix-matching filenames
there, not by a path relative to the `.mra`. A misplaced `.rbf` gives a silent flash-and-return-
to-menu before ROM loading begins.

Deploying and launching back-to-back needs an explicit `sync` plus a settle gap.

The two revisions are held to different standards; `docs/RELEASE_PROCESS.md` has the procedure.

## 4. Debug switches live in the OSD, on a hidden page

A full compile takes minutes, so **anything that might need changing during an investigation
belongs on a runtime switch, not in the RTL.** Per-layer render disables are the cheapest bisection
tool there is, and any "MAME's reading versus the other reading" question belongs on an A/B switch.

Rules that come with the pattern:

- **Every debug line carries an `H<n>` prefix** so the whole page hides in release builds, with the
  menumask bit tracking a macro defined only by the instrumented revision.
- **Render-disable switches per layer and for sprites**, from the first video build.
- **Make the all-zero configuration the correct one.** A fresh or missing `.CFG` is all zeroes, so
  word every switch so that 0 = normal.
- **Put the OSD Reset entries before the joystick lines in CONF_STR.** (Evidence: after them the
  entry was shown but `status[0]` never rose.)
- `scripts/cfg.py` sets bits by **read-modify-write** on `/media/fat/config/<setname>.CFG`
  (16 bytes = the 128-bit status word, little-endian, byte N = `status[8N+7:8N]`). Never hand-write
  a `.CFG`: zeroing every DIP while setting one debug bit silently enables Service Mode. The CFG is
  only read when the core loads.
- Validate bit assignments with <https://agg23.github.io/mister-config/> rather than reasoning
  about ranges. Collisions are silent; the symptom is an option that does not respond.
- **`status[0]` is Soft Reset.** Never use it for anything else.
- The `J1` button list **must** agree with the `.mra` `<buttons>` positions; pad every game to a
  fixed button count with `-` so Start, Coin and Pause land on the same joystick bits.

## 5. The JTAG probe

`rtl/debug/issp_probe.sv` — In-System Sources and Probes, read and poked over JTAG with
`quartus_stp -t scripts/read_issp.tcl`, under the section 2 lock.

**Why ISSP and not SignalTap:** SignalTap acquisition is GUI-only in Quartus Prime Lite 17.0. ISSP
is scriptable (`start_insystem_source_probe`, `read_probe_data`, `write_source_data`), which is
what a headless workflow needs, and it suits the questions a bring-up asks: "did this ever happen,
and how often", not "what does this waveform look like".

Keep the wrapper generic and build the probe bus in the module that owns the signals. The Tcl
decoder must be kept in step with the bit layout — say so in a comment at both ends.

The **source** direction is as valuable as the probe direction: pausing the CPU, selecting a
memory page to dump, re-arming a capture and stepping the SDRAM clock phase are runtime pokes that
would otherwise be rebuilds. One trap: `write_source_data -value` takes a **binary string**, and a
decimal one is silently rejected while still printing "source set to N". Pass `-value_in_hex`, and
read every source back after writing it.

**Every probe reading is labelled with what produced it: `<core>|<build>|<set>|`.** Several
sessions share one MiSTer, so the core that answers a JTAG read is whatever is loaded, not
necessarily the repository that asked. `read_issp.py` and `probe.py` prefix every line from
`scripts/identity.py`: the core file and set come from the device (`/tmp/RBFNAME`,
`/tmp/CORENAME`), the commit from a machine-wide deploy log that `deploy.py` appends to
(`%LOCALAPPDATA%/mister_deployed.tsv`). A field that cannot be established prints `?`, and when
the loaded core is not this repository's, a warning goes to stderr. Quote readings with their
prefix in notes, commit messages and messages to other sessions.

The authoritative check is in the bitstream itself: put a constant identity word on the probe bus
(a core tag and the build's commit, written into a header by the build) and compare it with the
prefix. The device and the log can disagree with what is actually in the FPGA; the bitstream
cannot.

## 6. Counters and the trace ring

`rtl/debug/debug_counter.sv` and `rtl/debug/debug_tracer.sv`, carried over with their design
rationale in the file headers:

- **No reset port at all.** Quartus powers registers to zero at configuration, so a counter with no
  reset shows what happened since the FPGA was programmed. A counter cleared by the reset under
  investigation reads `0` and gets reported as a finding — and MiSTer asserts reset for the entire
  ROM download.
- **Counters saturate rather than wrap.** A wrapped 3 could mean three or 65,539.
- **Every "bad event" counter is paired with a "total events" counter.** A zero otherwise cannot
  distinguish "did not happen" from "was never allowed to count".
- The tracer takes an explicit one-cycle `cap_stb` from the caller, so the capture point is a
  deliberate decision — proven in simulation against a known-good run before its hardware output is
  trusted. If a new probe reports a fault on a known-good setup, the probe is the fault.
- **`ctl_window` walks the capture across a long boot from the OSD with no rebuild.** Make the step
  odd (`window * 8191`) so it cannot alias with a power-of-two period.
- **Capture the full address.** Packing only `addr[7:0]` made a linear ROM sweep look exactly like
  a read path dropping its high bits.

Wire the first counters in from the first video build, not after a game looks wrong: sprites walked
per frame, pixels written per line, fetch stalls per line, DMA cycles per command — each paired with
a total.

## 7. Reading the trace out through the video output

The trace ring is read back as pixels and decoded from a screenshot
(`scripts/decode_debug_screenshot.py`, `scripts/tracer_readout.py`). Two things must be right:

- **Force the gamma LUT off under the overlay.** The framework applies the user's gamma curve to
  the core's RGB before the scaler and before screenshots; remapped trace values (`0x40 → 0x38`)
  read exactly like SDRAM data-lane corruption. Clear `gamma_bus[19]` whenever the overlay is on.
- **Draw each value and its bitwise inverse in alternating bands.** The pair must XOR to
  `0xFFFFFF`, so any transform in the capture path is detected rather than read as data.

`/dev/fb0` is the ARM-side OSD overlay surface, not the FPGA's composited video — never use it as
evidence about the core's video pipeline. Use the screenshot API, and poll for a new file under
`/media/fat/screenshots/<core-shortname>/` because `POST /api/screenshots` returns an empty body
regardless of success.

VGA-colour-override builds remain the crudest and most reliable instrument for a yes/no question:
override `VGA_R/G/B` with a solid colour gated by an internal signal and take one screenshot.

## 8. Reading memory back out of a running core

`scripts/memdump.py` reads SDRAM, VRAM, palette, sprite RAM, video registers and work RAM out of
the running core over JTAG with the CPU paused, optionally diffing against an expected image.
`scripts/boot_trace.py` captures the first N CPU accesses, or the N before the first exception, or
the N before a JTAG pause, and compares against MAME.

Build it early; it answers hardware questions directly instead of arguing from simulation.
(Evidence: it settled a work RAM indexed one bit too narrowly and an arbiter still packing 25-bit
addresses after a widening, neither of which simulation saw.)

`scripts/wait_scene.py` polls screenshots until the frame matches a reference crop and holds the
CPU paused there. `scripts/sweep.py` launches every deployed set in turn and tabulates the probe
side by side — one black screen is consistent with several faults, and comparing sets separates
them. `scripts/soak.py` runs a game for N seconds sampling the probe and a screenshot, and flags a
hang.

## 9. MAME as a reference generator

Reference data is **captured, not hand-made**, so any claim about the hardware can be re-checked
the same way by anyone with a MAME install and the ROM sets. `scripts/mame_capture.py` drives MAME
headlessly through `scripts/mame/*.lua` and captures video regions, screenshots and register write
logs.

What this makes provable offline, before hardware exists:

| Reference | Validates |
|---|---|
| Boot program trace (PC / bus cycles) | The CPU end to end against the memory map — diffed against the simulator's trace. Catches wrong interleave, wrong reset vector, wrong IRQ timing and wrong DTACK behaviour in one test |
| Program ROM disassembly at known offsets | The `.mra` interleave, with no build and no hardware |
| VRAM and video register dumps at a known frame | Every video engine: preload the dump, render one frame in sim, compare against MAME's output for that frame |
| Palette RAM dump | The colour path |
| Write taps over a boot | Which RAM pages a game actually writes — the measurement the RAM budget depends on |

The pipeline, in order: `mame_capture.py <set> --frame N` dumping every video RAM and register
block through the CPU's address space; `render_model.py` reproducing the driver's video file and
reporting the pixel match against MAME's own screenshot; then the RTL checked against the model,
layer by layer. **The model is checked against MAME first and the RTL against the model.**

Traps:

- **Keep every Lua subscription in a variable that outlives the call.** `add_machine_frame_notifier`
  and `install_write_tap` return subscription objects; dropping the return value lets the GC reclaim
  them and the callback **silently stops firing**, with exit status 0.
- **Check `mame.ini` for `debug 1` and pass `-nodebug` explicitly.** Otherwise every launch halts in
  the debugger while the autoboot script still loads and prints. Same for `window 1` when headless.
- **Wrap the Lua in an error-catching runner** that writes failures to a file the Python side reads
  back — a broken script otherwise fails as an invisible modal dialog.
- **Probe which Lua API this MAME build actually provides** rather than writing against the online
  docs.
- **Read dumps through the CPU's own address space** (`spaces["program"]:read_u16(addr)`), not out
  of MAME's internal structures — that returns what the CPU would read, device handlers included,
  which is what the RTL has to match.
- Snapshots work under `-video none` and land one directory deeper than the one given.

Two cautions on what a comparison proves: a hardware-vs-image comparison **cannot detect a wrong
image** when both sides were built from the same byte-order assumption, and a test using uniform or
all-zero content is invariant under byte order. Use real content.

## 10. Simulation

`scripts/run_sim.sh` compiles the RTL and runs one testbench from the repository root, and
**rebuilds the `work` library every run**. A ModelSim compile killed by a tool timeout leaves
`work/_lock`, on which every later `vlog`/`vcom` waits silently. A bench that prints nothing has
usually not run.

Vendored jotego modules need `+define+SIMULATION +initreg=r+0 +initmem=r+0`: their un-reset
pipelines are X in a four-state simulator and zero in hardware. That flag has its own trap
(LESSONS_LEARNED, "`+initreg=r+0` turns an un-evaluated `always @*` into a confident zero").

Sweep for orphaned `vsimk.exe` kernels at the start of any session that runs simulations — killed
runs leave them spinning at 100% CPU:

```powershell
Get-Process vsim,vsimk | Select-Object Id,ProcessName,CPU,WorkingSet64,StartTime
```

`taskkill //PID <n> //F` fails against these; `Stop-Process -Force` succeeds.

**Verilator is the second simulator, and the fast one** (`scripts/run_verilator.sh`, MSYS2's
mingw64 package, driven through the msys bash). It is two-state, so anything that turns on
X-propagation stays on ModelSim; VHDL is outside it, so a VHDL CPU goes through GHDL's Verilog
conversion (`scripts/verilator_prep.sh`; KonamiGX's `tg68k_verilog.sh` is the pattern). Build the model at `-O2`, one thread —
`--threads` made a clock-per-eval model slower with an identical trace. A disagreement between the
two simulators is a finding, not a nuisance. Verilator does not need the section 2 lock.

Long main-board runs start from a snapshot: give the bench its own `main.cpp` that drives the clock
and saves or restores the whole simulation. A restored run's trace must be byte-identical to an
uninterrupted one's; check that once. A snapshot holds the ROM images and any scripted replies:
remake it after either changes. Two runs at once need their own `--out` directories.

Simulation, MAME and the board are compared from a memory snapshot, a few frames per run: take the
state at the frame of interest (MAME's Lua, or the board through the probe), load it into the bench,
run a few frames, compare. Do not simulate hundreds of frames from reset to reach a scene or to
regression-check a build; a from-reset run to frame 1500 took 1,318 s of wall time (BallySente
board_tb) and held up the build it was meant to clear. Audio is judged by ear on the board, not by a long run. Where a bench
cannot load a snapshot yet, add that rather than falling back to long runs.

The rest of testbench discipline is in LESSONS_LEARNED's "Testbench discipline" section — read it
before writing a new bench rather than after one gives a confident wrong answer.

## 11. `.mra` generation

Generate every `.mra` from a script (`scripts/build_mra.py`), not by hand:

- Each region is built from the driver's `ROM_START` semantics, and **the map digits are found by
  testing against that**, not derived by reasoning. (Evidence: every interleave one sibling derived
  by reasoning was wrong.)
- A BIOS region that every set shares belongs in every `.mra`.
- Every `<part>` carries its CRC, and the zip attribute lists the cascade
  (`set.zip|parent.zip|bios.zip`). Testbench fixtures are built through `scripts/mra.py`, which
  finds parts by CRC first and ignores directories inside the zip, so a bench and the board accept
  the same zips.
- The finished file is **re-read and compared byte-for-byte** against an image built directly from
  `ROM_START` (`scripts/mra.py` reimplements mra-tools-c's semantics).
- SDRAM offsets come from the RTL's own address map (its localparams), never duplicated into the
  generator.
- Parents land in `releases/`, clones in `releases/_alternatives/`.
- Every `.mra` is gated on an **XML well-formedness check** before deploy. A stray `<` inside a
  prematurely-closed comment gives a black screen whose every symptom points at the RTL.
- A `<dip>`'s `bits` attribute is a **range**, `"first,last"` — `Main_MiSTer` reads it with
  `sscanf("%d,%d")`.
- Pad every game to a fixed button count with `-`; the CONF_STR `J1` list **must** agree with the
  `<buttons>` positions.
- When a mod byte gates download-time logic, list `<rom index="1">` **before** `<rom index="0">`.
- When testing an `.mra` change, **force a genuine reload** by bouncing through `menu.rbf` — a
  relaunch reuses the cached ROM and produces a byte-identical trace.

## 12. Vendored modules: their own tests are the regression

- **Every vendored directory gets a `PROVENANCE.md`** recording the upstream repository, the exact
  commit, the licence as stated in the files (not as reported by GitHub's licence detector), what
  was changed and why.
- **Store vendored files byte-for-byte**: a `-text` line per directory in `.gitattributes`, so
  "verbatim at <commit>" stays checkable and `git log -p` on the directory is the record of every
  local divergence.
- **Run the upstream tests on arrival, before editing anything.** A vendored block that fails its
  own tests on arrival is a porting problem, and finding that out after local edits is how a day
  is lost.
- **Re-run them after every edit**, as the regression they now are.
- **GPLv3 §5(a): a modified file must state prominently that it was changed, and when.** Append to
  upstream's header, never replace it, never tidy the notice away. It is a licence term, not a
  comment. Keep the unmodified original beside it as `*_upstream_reference` where the diff is
  non-trivial.
- **Generated files** (register-map modules from a generator upstream does not commit) are
  committed here with the generator vendored under `tools/`, and a `--check` script detects drift.
- **Where a vendored module and MAME disagree, record it and keep the module.** It goes in
  `docs/MAME_KLUDGES.md`, not into a "fix".
- **Suspect your own integration before any vendored module.** When the board misbehaves, the
  wiring, the memory map and the clock domains are ours.

## 13. Branching and history

`develop` is the working branch and carries granular commits, committed as work lands without
being asked each time. It is **not pushed**. At intervals that work is **squashed onto `master`**,
which is what gets pushed — and only when the user asks for it. `master` is a curated history of
milestones, not a replay of every bisection step.

A build that the user rejects has its commit **reverted**, not left in the branch for later: the
history should not carry a bitstream nobody accepted.

ROMs live in `roms/` and are **gitignored** — no ROM data is ever committed.

`.gitattributes` pins `*.sh` and this project's `scripts/**/*.tcl` and `*.lua` to LF, scoped so
`sys/*.tcl` is untouched. With `core.autocrlf` on, a `git reset --hard` otherwise gives them CRLF
and bash rejects `set -euo pipefail\r` on line 1.

## 14. No multiplies, no divides, in 2D pipelines

The rule covers traditional 2D video (sprites, tilemaps, zoom, line buffers, mixers) and the
glue around the CPUs. GPU-like chips are the exception: 3D geometry, transform and lighting,
perspective correction and rasterisers are built on multiplies and divides, and use DSP blocks as
the design, not as a workaround. Budget their DSP blocks in the roadmap.

In a 2D pipeline, a `*` in RTL is a DSP block or a wide LUT multiplier; a `/` is a large combinational divider.
Neither is what the original chips did, and both cost area and Fmax. Express the arithmetic with
**shifts, masks and adds** even where MAME writes a multiply or a divide: `x * inc` inside a loop
is an accumulator stepped by `inc`, `/ 256` is `>> 8`. Where a product is genuinely needed and not
every clock, a serial shift-add stepper is the form. Where one must stay at pixel rate, keep it to
a DSP-sized width and say so in a comment. Before committing RTL, grep it for `*` and `/` outside
comments.

## 15. Licence headers

- **Every new source file starts with `// SPDX-License-Identifier: <licence>`** and a copyright
  line. One line each, at the top, before anything else.
- **A vendored file keeps its upstream copyright and its upstream change notice** (section 12).
- **`sys/` is never edited.** Build-time behaviour changes go in the `.qsf` as `VERILOG_MACRO`
  settings.

Full reasoning and the release checklist live in `THIRD-PARTY.md`.

## Script inventory

`skill` means `new_core.py` already copied it into `scripts/`, generic, with a marked per-core
block (the skill's `references/SCRIPTS_NOTES.md`). The rest are ported from the named sibling with
header comments intact: the rationale in those headers is why they have the shape they do. Mark
each **done** as it lands.

| script | why | from |
|---|---|---|
| `hwlock.py` | **first**, before any build: section 2 | skill |
| `build_staged.py` | worktree build at `build/`, refuses dirty tree, gates on slack, instances, macros | skill |
| `deploy.py` | slack-gated deploy, incrementing `.rbf` numbering, fallbacks on device | skill |
| `run_sim.sh` | one testbench, fresh `work` library every run, takes the lock | skill |
| `run_verilator.sh` | the fast second simulator; outside the lock | skill |
| `mra.py`, `extract_dips.py`, `validate_mra.py` | verify byte-for-byte, extract DIPs, check every `.mra` | skill |
| `build_mra.py`, `check_dips.py` | generate every `.mra`; parse-check the DIP blocks | Seta, GX |
| `extract_romstart.py` | `ROM_START` straight from the driver | skill |
| `build_rom_image.py`, `build_region.py` | the ROM image the benches load | GX, Seta |
| `cfg.py` | read-modify-write of the per-core `.CFG` status word | Seta, Fuuki |
| `read_issp.tcl`, `read_issp.py`, `probe.py` | read the probe / write the source bus over JTAG | skill |
| `report_worst_paths.tcl`, `sta_*.tcl` | worst setup paths from the compiled database | skill |
| `mame_capture.py` + `mame/*.lua`, `write_timing.py` | headless MAME reference capture; video-write sweep | skill |
| `render_model.py` | the software model of the driver's video file | GX, MS32 (pattern only) |
| `mame_boot_trace.py`, `mame_sys_trace.py`, `compare_boot_trace.py` | the CPU trace diff against MAME | skill |
| `diff_core_trace.py` | RTL-side trace diff | Seta |
| `decode_gfx.py`, `gfx_sheet.py` | decode tiles straight from the ROM zip | Seta, Fuuki |
| `memdump.py` | read any CPU-visible memory out of a running core | Seta, Fuuki |
| `decode_debug_screenshot.py` | trace ring readout through the video path | skill |
| `tracer_readout.py` | the same, for the tracer's ring | Seta, Fuuki |
| `hw.py` | launch, screenshot, what is playing | skill |
| `wait_scene.py`, `sweep.py`, `soak.py` | hold a chosen scene, compare sets, detect hangs | Seta, Fuuki |
| `sdram_pattern_test.py`, `sdram_dump_check.py` | known-pattern SDRAM test through the real download path | Seta, Fuuki |
| `regen_mmr.sh --check` | drift check for generated register-map modules, where used | GX |

And from `rtl/debug/`: `issp_probe.sv`, `debug_tracer.sv`, `debug_counter.sv`, `pause_control.sv`.
