# Release process

Two Quartus revisions, held to different standards. This is the procedure for turning a build into
something other people run.

| | `<Name>_stp` (debug) | `<Name>` (release) |
| --- | --- | --- |
| Built by | `build_staged.py` (default) | `build_staged.py --rev <Name>` |
| Contains | ISSP probes, debug tracer, Debug OSD page | none of it — compiled out |
| Timing | **may ship with negative slack** | **must close timing** |
| Goes to | our own DE10-nano | `releases/`, other people's hardware |

The asymmetry is the point. A debug build runs on hardware we control, in front of someone who
knows what a marginal path looks like, and the instrumentation costs timing a release does not pay.
A release build goes to hardware we cannot see, where a path that only just fails becomes an
intermittent glitch someone else has to chase. So negative slack is qualified for the debug revision
and disqualifying for a release.

`build_staged.py` enforces this: it reads every clock in the `.sta.summary` — not just `clk_sys` —
and refuses to print the deploy command if any fail, naming the offenders.
`--allow-negative-slack` overrides it, prints a warning instead, and obliges you to state the
shortfall in the release notes.

It also gates on two things slack cannot see, both of which have shipped a falsely-green build on a
sibling core: every block in `REQUIRED_INSTANCES` survived to the fitted netlist, and every macro
in `REQUIRED_MACROS` is defined in the revision's `.qsf`. Keep both lists current as modules land.

Steps for a release:

1. `python scripts/build_staged.py --rev <Name>` — must pass the timing gate, the presence gate and
   the macro gate.
2. Smoketest every parent set (a smoke-test or sweep script: Seta's and Fuuki's `scripts/sweep.py` are the ones to port): load each, capture a
   screenshot, compare against the reference crop.
3. Deploy and play-test; the debug revision is the one to reach for if anything needs diagnosing.
4. Run the `THIRD-PARTY.md` release checklist: every vendored directory has a current
   `PROVENANCE.md`, every modified vendored file carries its change notice, `sys/` is unmodified,
   every open licence question is answered or that code is out of the build.
5. Publish the `.rbf` and the whole `.mra` set together under `releases/`. They are coupled — the
   SDRAM layout and the ROM-load path are both encoded in the MRAs, so a mismatched pair fails in
   ways that look like core bugs. Parents at the top level, clones in `releases/_alternatives/`.
   The `.rbf` is `Arcade-<Name>_YYYYMMDD.rbf`; `releases/*.rbf` is gitignored, so add it with
   `git add -f` deliberately, and only a build verified to run the games.
6. Record the commit **and the fitter seed** from `build/BUILT_COMMIT` in the release notes, with
   the worst slack per clock and the resource table. A commit alone does not identify a bitstream:
   two builds of one commit at different seeds have differed in which games ran.
7. Update `README.md`: History, Supported table, Status, Resource usage.

**Current state:** `Arcade-Vamphalf_20261009.rbf`, release revision at `fe5d6fa` seed 7, every clock meets timing (worst setup +0.564 ns, hdmi pll; clk_sys +0.957 ns; worst hold +0.185 ns); played on the board by the user, all games working; no smoketest script yet (step 2).

## Submitting the core upstream

From the contribution guidelines (https://github.com/MiSTer-devel/Wiki_MiSTer/wiki/Contributing-a-Core-to-MiSTer-FPGA); check each before asking for a release.

- Public repository, licence compatible with the framework (GPL-3.0 here), standard layout
  (`sys/`, `rtl/`, `releases/`), and the template's own files present and named for this core.
- `sys/` matches the template: no local edits.
- `releases/Arcade-<Name>_YYYYMMDD.rbf` is a build verified on hardware, committed with
  `git add -f`.
- One primary `.mra` per game in `releases/`, alternatives in `releases/_alternatives/_<game>/`,
  no filename clashes with existing platform `.mra` files.
- The `<rbf>` tag names the core without the `Arcade-` prefix (`<rbf><Name></rbf>`), matching the
  name `deploy.py` installs; the released file keeps the prefix, and the README's install step says
  to drop it.
- Every `.mra` regenerated against the current MAME, so `<mameversion>` matches it and the
  CRCs were re-verified against that release's set definitions.
- `validate_mra.py` passes without `--allow-generic-buttons`: button names from the manual, and
  every DIP line within the OSD's 28 columns.
- Video output checked over direct video into a scaler where one is available, else the
  scandoubler over HDMI and the analog output: steady pixel width, line and frame rate.
- Every supported game fully playable; anything not playable is out of the supported list, in the
  README's "Not yet" table, not shipped as broken.
- AI-assisted work: the guidelines expect readable code, testing and accuracy verification. The
  README's AI attestation section and `docs/` hold the evidence: MAME references, benches,
  `HACKS.md` and `MAME_KLUDGES.md`.
- Submission is by email to newcores@misterfpga.org with the repository link; the core is then
  transferred into the MiSTer-devel organisation (the author stays maintainer) and added to the
  List of Cores wiki page. **The user decides when to submit; never contact anyone on their
  behalf.**

Compilation reference, including the Quartus 17.0.2 the framework expects: https://mister-devel.github.io/MkDocs_MiSTer/developer/mistercompile/
