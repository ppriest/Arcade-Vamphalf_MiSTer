# Vamphalf

MiSTer arcade core for Vamphalf. Built with the `mister-arcade-core` skill.

## Before working

- `docs/ROADMAP.md` is the status and plan. No phase starts until the user approves it.
- Read the routing table at the top of `docs/LESSONS_LEARNED.md` before starting a
  subsystem.
- `docs/WORKFLOW.md` is binding.

## Rules

- Never touch `sys/`.
- Build with `python scripts/build_staged.py`, never in the tree. Commit first; it
  refuses a dirty tree.
- No JTAG while Quartus runs, and the reverse. Use `scripts/read_issp.py` and
  `scripts/probe.py`, which take `hwlock.py`.
- Deploy only with `scripts/deploy.py`. Launch and screenshot with `scripts/hw.py`,
  `--native` for pixel comparison. Deploying is always fine; launching or resetting takes the
  board from whoever is using it, so only when asked. Announce long compiles: they block every
  session's JTAG (`docs/WORKFLOW.md`, section 2a). JTAG has priority: a session waiting for the
  Blaster reserves it, and no new build or simulation starts while that reservation stands
  (`python scripts/hwlock.py --status`).
- Commit to `develop` as work lands. Never push `develop`; squash onto `master` only when asked.
  Revert the commit of a build that is rejected.
- MAME is the reference. Follow it where it is wrong and log it in `docs/MAME_KLUDGES.md`.
- Anything approximate, stubbed or special-cased goes in `docs/HACKS.md` when written.
- Every subsystem gets a testbench fed from a MAME capture before it goes on hardware.
- Run the video-write sweep before choosing any sprite or tile buffering scheme.
- `clk_sys` defaults to ~48 MHz with the SDRAM on it, not doubled; higher only for a measured
  shortfall, agreed with the user. It is the video clock and an integer multiple (4x or more)
  of the pixel clock; every component runs on a fractional clock enable from it. Check direct
  video through a scaler.
- DDR3 at load time is standard; DDR3 during play needs a reason in the roadmap's memory plan.
- Display aspect is 4:3 (3:4 rotated), never derived from the pixel resolution; an exception
  needs a driver source line.
- Render per scanline from buffered sprite RAM. A frame buffer needs evidence that the board had
  one; a tight per-line budget is a conversation with the user, not a change of shape.
- The standard feature set (README "Features") is part of done, not polish. Flip screen is one
  path from the OSD or the DIP, verified against the unflipped frame rotated 180 degrees, not
  against MAME alone. The OSD shows only what applies to the running set and output.
  Controls always include a Pause input that suspends the main CPU. Savestates and cheats
  are optional to ship, but keep state reachable and `docs/STATE.md` current as RTL lands:
  retrofitting state capture is the expensive path, and the state dump is what makes a
  hardware bug reproducible in a bench.
- Debug switches live on the OSD's hidden page, and probes in the `Vamphalf_stp` revision
  only.
- No multiplies or divides in 2D video or CPU glue: shifts, masks, adds, accumulators
  (WORKFLOW §14). GPU-like chips (3D geometry, rasterisers) use them by design.

## Style

- Comments say what the code cannot. Delete or rewrite them when they go stale.
- No dates unless load-bearing, no invented durations, no narrative.
- A hardware claim cites its evidence: screenshot path, probe readout, log line.
- New general lessons go in `docs/LESSONS_LEARNED.md` tagged `[Vamphalf]`.
