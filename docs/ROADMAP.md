# {{HARDWARE_NAME}} — MiSTer Core Roadmap

**This roadmap is a proposal until the user approves it. No phase executes before that approval,
and a phase whose scope changes goes back for approval.**

## Context

Goal: a DE10-nano MiSTer core for {{HARDWARE_NAME}}, emulated by MAME's `{{MAME_DRIVER}}` and the
devices it instantiates — a Quartus 17.0.2 Verilog/SystemVerilog project producing one `.rbf` and a
`.mra` per supported set, reusing proven open components where they exist.

{{WHAT_SHAPES_THIS_PROJECT}}
<!-- The one fact that sets the shape: how much already exists in open RTL, whether the CPU is
     proven in a sibling core, what has no implementation anywhere. Then a numbered list of what
     is genuinely new work. Everything else is a port with verification. -->

Cross-cutting findings from the previous cores are in **[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**.
Working practice built on them is in **[`WORKFLOW.md`](WORKFLOW.md)**. The entries that already
bind decisions here are collected under "Pitfalls that already bind decisions here".

## Progress

{{PROGRESS}}
<!-- Kept current. Opens with one bold sentence on where the project is. Every number says where
     it came from: MAME source, a sibling core's measurement, a build report, a bench run. Use
     "N of N" counts, not adjectives. Strike through closed items while a later reader needs the
     history; delete them when nobody does. -->

## Game scope

{{SET_TABLE}}
<!-- Generated from each ROM_START: set, board type, machine config, loaded bytes per region,
     MAME flags. Loaded bytes, not declared region size. -->

### Scope decision

- **In scope:** {{IN_SCOPE}} — one memory map, one screen, one chipset, fits the SDRAM module.
- **Out of the first scope:** {{OUT_OF_SCOPE}} — give two independent reasons where they exist.
- **First-target set:** {{FIRST_TARGET}} — the smallest set with the least protection involvement.
  Final choice is a Phase 0 decision, made on which boots furthest, measured.
- **Second target:** {{SECOND_TARGET}} — the set that exercises the next variant.

## Hardware reality (from the driver, not assumption)

Every value below is read out of the MAME driver or a device file and cites file and line. A
value from a datasheet, a schematic or a PCB measurement says so.

### Chips

{{CHIP_TABLE}}

### Clocks

{{CLOCKS}}
<!-- The plan, before any RTL (the skill's clocks.md). Every board clock with its source line
     and the pixel clock; the chosen clk_sys, which is also the video clock, with the candidates
     considered and the arithmetic, starting from ~48 MHz with the SDRAM on the same clock; any
     higher value carries the measurement that forced it: an integer multiple (>= 4x) of the pixel clock, >= every
     board clock, and a base for an integer SDRAM multiple. The SDRAM multiple. Every fractional
     clock enable with its exact ratio. How far the main CPU runs ahead to catch up SDRAM stalls.
     Any clock that does not divide exactly, in ppm, also goes in HACKS.md. -->

### Interrupts

{{INTERRUPTS}}
<!-- Levels, sources, HOLD_LINE vs ASSERT_LINE in the driver, the enable/ack registers, and the
     vectors as read from the program ROM. -->

### Memory map

{{MEMORY_MAP}}

### Video

{{VIDEO}}
<!-- Layers, sprite format, colour depths, palette format, priority/mixing model, screen flip,
     what MAME says it does not emulate. -->

### Sound

{{SOUND}}

### Protection

{{PROTECTION}}

### Per-game configuration

{{PER_GAME}}
<!-- Everything that differs between sets and so becomes .mra mod-byte configuration. -->

## Component reuse map

Every row's "source" is a file that was located and whose header was read.

| block | plan | source |
|---|---|---|
{{REUSE_MAP}}
<!-- plan: "Port X" / "Written from the software model" / "From scratch" / "Sibling core's Y".
     source: repository, path, commit, licence as stated in the files. Built by enumerating the
     boards that use each chip and looking at those boards' cores, not by searching for the chip
     number. -->

## On-chip RAM budget

{{RAM_BUDGET}}
<!-- Every declared memory, its bits, its M10K count at the width it is actually read at, as a
     fraction of the device, starting from the framework's own baseline. Name the one to watch. -->

## Memory plan

{{MEMORY_PLAN}}
<!-- SDRAM region layout (the RTL's localparams are the source of truth; the .mra generator reads
     them), DDR use if any, the clients of each and the per-scanline fetch budget. DDR3 at load
     time is standard; any DDR3 client during play (ROM, graphics, frame buffer) states its
     reason here: ROMs larger than the SDRAM, or fetch arithmetic SDRAM cannot serve. -->

## Design decisions

<!-- Each a bold sentence, then the evidence. Standing rules first, project decisions after. -->

**Follow MAME, including where MAME is wrong, and write down every place that is.** There is no
PCB here. MAME is the accuracy target and its acknowledged guesses are inherited deliberately. Each
goes in `docs/MAME_KLUDGES.md` when it is implemented, with what MAME does, what the hardware is
suspected to do, and what would settle it.

**Where a vendored module and MAME disagree, record it and keep the module.** A silicon-derived
disagreement is evidence about the chip; MAME's is evidence about MAME. It goes in
`docs/MAME_KLUDGES.md`, not into a "fix", until one side is shown to describe the chip.

**Every approximation of this core's own goes in `docs/HACKS.md`** in the commit it lands, with
what would make it correct. A hack that is not written down is a bug nobody will find.

**Transcribe the reference literally first, then look for the chip.** Build MAME's version, get
pixel-exact (or trace-exact) agreement with captured references, and only then experiment — with
the experiment on an OSD switch so it is an A/B, not a rebuild.

**One `.rbf` for all games.** Per-set differences are `.mra` mod-byte configuration.

**Two Quartus revisions, `Vamphalf_stp` and `Vamphalf`,** differing only by a `DEBUG_ISSP` macro.
See [`WORKFLOW.md`](WORKFLOW.md).

**Licence: {{LICENCE}}.** Every dependency, what it obliges and the release checklist are in
[`THIRD-PARTY.md`](../THIRD-PARTY.md). `sys/` is never edited.

**Per-scanline rendering from buffered sprite RAM.** The default shape, as the boards worked:
the list latched once a frame at the point the video-write sweep identifies, a per-scanline
engine, a double-buffered line buffer. A frame buffer only where the driver shows the board had
one; cite it here.

**No multiplies, no divides, in 2D pipelines.** Shifts, masks, adds and accumulators; WORKFLOW §14.
GPU-like chips (3D geometry, rasterisers) use multipliers by design, budgeted in DSP blocks.

{{PROJECT_DECISIONS}}
<!-- Clocking plan and the measurement it rests on; CPU integration choice; sprite rendering
     shape (line-based, not frame-buffered, and why); which memory each large array lives in. -->

## Pitfalls that already bind decisions here

Entries from [`LESSONS_LEARNED.md`](LESSONS_LEARNED.md) that are not general advice but already
constrain something written above. Read the entry, not the summary.

| Entry | What it binds here |
|---|---|
{{PITFALLS}}

## Phased roadmap

<!-- Phase 0 is the gate: nothing after it starts until its exit criteria are met, and each
     criterion is answered in place ("— Met: <evidence>" / "— Open: <what is missing>"). -->

**Phase 0 — Vendoring spike and the measurements. The gate.**

Vendor every reused module into `rtl/` with a `PROVENANCE.md` per directory. Run every upstream
testbench unchanged before editing anything. Stand the CPU up in its own Quartus project
(`rtl/synth_check/`) with the bus wrapper and the memory transport and nothing else.
Exit criteria:

1. **Every vendored module's own tests pass unchanged, on arrival.**
2. **The CPU boots the first target's program ROM and matches MAME's bus trace**, diffed access by
   access, every peripheral stubbed to what MAME's returns.
3. **Measured CPI on real game code** against the board's clock, split between execution and
   memory stall.
4. **Standalone Fmax and area for the CPU at this project's settings**, with the constraint that
   proves it committed in the same commit as the measurement. This decides the clock plan.
5. {{PHASE0_PROJECT_SPECIFIC_QUESTION}}

**Phase 1 — Video, against a software model.**

Build the MAME capture pipeline first (`mame_capture.py` + a `render_model.py` that reproduces the
driver's video file), get it pixel-exact on captured frames, then check RTL against the model layer
by layer. Exit criteria: the first target renders frames pixel-identical to MAME's for a captured
set of scenes, silent, in simulation.

**Phase 2 — Hardware bring-up and the first games.**

SDRAM backend with all clients, the ROM download path, `.mra` generation, inputs, DIPs, NVRAM,
the ISSP probe and the OSD debug page. The standard feature set: CRT Adjust (and v-size if BRAM
allows), hiscore, fast DDR ROM loading, HDMI scaling and crop, HDMI rotation, audio mix, HDMI-only
options hidden under direct video, CRT Adjust parameters hidden until enabled, peripheral menus
only for games that use them (rotary: Ikari Warriors controls; guns: mouse and synthetic
crosshair), and flip screen from the OSD or the DIP (fake DIP where the
game has none) through one path, worked out per layer for this board. Exit criteria: {{PHASE2_SETS}} boot and play on a
DE10-nano, silent.

**Phase 3 — Sound.**

{{SOUND_PLAN}}. Exit criteria: register-write traces captured from MAME reproduce correct audio,
by ear and by a decoded capture against MAME's output.

**Phase 4 — The rest of the list, and accuracy.**

The remaining sets, every clone's `.mra`, {{PHASE4_ITEMS}}. `docs/MAME_KLUDGES.md` and
`docs/HACKS.md` are the deliverables that say what is still not right and what would settle it.

**Phase 5 — {{OPTIONAL_SCOPE_EXTENSION}}.** A decision with evidence rather than a default.

**Phase 6 — Savestates, state dumps and cheats.** Optional but desirable. Not before Phase 4, but
the RTL is written for it from Phase 1 (the skill's `savestates.md`): reachable RAM ports, a
`docs/STATE.md` inventory, addressable chip state. The state dump and its simulator loader are worth
building before the savestate itself, because they make hardware bugs reproducible in a bench.

## Verification strategy

- **MAME is a reference generator, driven from scripts, not a thing to eyeball.** Boot traces, VRAM
  and register dumps at known frames, palette dumps, register-write logs. WORKFLOW §9 applies.
- **The software model comes before the RTL.** The model is checked against MAME first; the RTL
  against the model.
- **Every vendored module is verified against MAME before it is wired to anything**, and its own
  testbench is the regression for every later change to it.
- **Layouts are verified before ROMs are involved**: every `gfx_layout` gets the "every bit of a
  tile exactly once" check.
- **`.mra` files are generated, not written**, re-read byte-for-byte against an image built from
  `ROM_START`, and gated on an XML well-formedness check before deploy.
- **Worst cases are measured in the RTL**, not modelled: saturating counters with no reset port,
  each paired with a total.

## Repository setup

Seeded from **MiSTer-devel/Template_MiSTer**, `Template.*` renamed to `Vamphalf.*` and split into
the `Vamphalf_stp` and `Vamphalf` revisions; the Quartus 13 project dropped. Quartus **17.0.2**.
Conventions are in [`WORKFLOW.md`](WORKFLOW.md) and `CONVENTIONS.md`.

## Open items

{{OPEN_ITEMS}}
<!-- One bold sentence each, then what is known, what is assumed, and what closes it. Strike
     through when closed and say what closed it. -->

## Next steps

1. {{NEXT_STEP}}
<!-- Numbered, in order, struck through as done with a pointer to the evidence. -->
