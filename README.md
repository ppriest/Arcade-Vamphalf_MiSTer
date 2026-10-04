# {{HARDWARE_NAME}} core for MiSTer

A MiSTer FPGA core for {{MANUFACTURER}}'s {{HARDWARE_NAME}} arcade hardware (MAME's
`{{MAME_DRIVER}}`), built with Quartus Prime 17.0.2 Lite for the DE10-nano.

**Status: {{STATUS_ONE_LINE}}.**

## Contents

- [History](#history)
- [Games](#games)
  - [Supported](#supported)
  - [Not yet](#not-yet)
  - [Out of scope for now](#out-of-scope-for-now)
- [Hardware](#hardware)
  - [Video timing](#video-timing)
- [Screenshots](#screenshots)
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

{{HISTORY}}
<!-- One paragraph per release or milestone, newest first. Name the commit for anything that
     ran on hardware. "No release yet" is a valid entry. -->

## Games

{{SCOPE_ONE_PARAGRAPH}}
<!-- Which board types / machine configs the core targets, how many sets, SDRAM size they need. -->

### Supported

Sets with an `.mra` in `releases/`. {{WHICH_HAVE_RUN_ON_HARDWARE}}

| Name | Year | Manufacturer | {{PER_CORE_COLUMNS}} | Notes |
|-|-|-|-|-|
{{SUPPORTED_SETS_TABLE}}

### Not yet

In-scope sets the RTL does not take yet, and why.

| Name | Why |
|-|-|
{{NOT_YET_TABLE}}

### Out of scope for now

| MAME description | Why |
|-|-|
{{OUT_OF_SCOPE_TABLE}}
<!-- Reasons that count: MACHINE_NOT_WORKING in MAME, a device MAME lacks, ROM set larger than the
     SDRAM module, a second monitor, a bootleg with different sound hardware. -->

## Hardware

| Chip | Function | Status |
|-|-|-|
{{CHIP_TABLE}}
<!-- One row per chip. Status says where the RTL came from (written here / vendored from X with
     changes / MAME transcription) and what it has been checked against. -->

### Video timing

{{VIDEO_TIMING}}
<!-- Dot clock, dots per line, lines per frame, the resulting line and frame rates, the visible
     area, and where the numbers come from (CRTC registers, MAME set_raw, a PCB measurement). Say
     if MAME's declared rate differs. -->

## Screenshots

### {{GAME}}

![{{set}} title](docs/screenshots/{{set}}/title.png)

## Installation

{{SDRAM_REQUIREMENT}}
<!-- e.g. "A 32 MB SDRAM module is required." -->

* Take the latest `*.rbf` from `releases/` and put it in `_Arcade/cores`, renamed to drop the
  `Arcade-` prefix (`Arcade-Vamphalf_YYYYMMDD.rbf` becomes `Vamphalf_YYYYMMDD.rbf`). MiSTer launches
  the highest-sorting match for `<rbf>Vamphalf</rbf>`, and a `Vamphalf_*.rbf` sorts above every
  `Arcade-Vamphalf_*.rbf`
* Take the `*.mra` files and the `_alternatives` folder from `releases/` and put them in `_Arcade`
  (or a subdirectory starting with an underscore, e.g. `_Arcade/_{{HARDWARE_NAME}}`)
* Put the MAME merged or split ROM sets in `games/mame`{{BIOS_NOTE}}

To run a development build instead: `python scripts/build_staged.py`, then `python scripts/deploy.py`
with a `mister.env` (see `scripts/deploy.py`).

## Controls

{{CONTROLS}}

Keyboard, MAME's defaults: arrows / R F D G, buttons LCtrl LAlt Space LShift Z X / A S Q W E,
Start 1 / 2, Coin 5 / 6; F2 service switch, 9 / 0 service coins, P pause.
<!-- The J1 line's button names in order, what Start/Coin/Pause/Service map to, and per-game
     exceptions. Must agree with the .mra <buttons> positions. Light gun / trackball / mouse
     options if any. -->

## Status

Known issues:
{{KNOWN_ISSUES}}
<!-- Bulleted. Bold the ones a player would notice first. -->

`docs/MAME_KLUDGES.md` lists what is taken from MAME as behaviour and what is known not to be
right. `docs/HACKS.md` lists this core's own approximations. `docs/ROADMAP.md` is the plan and its
progress; `docs/LESSONS_LEARNED.md` is what it cost.

### Features

<!-- Keep every line; mark each done / not yet / n-a so the gaps are visible. -->

* DIP switches from the `.mra` (`DIP;` in the OSD): {{DIPS_STATUS}}
* Inputs: {{INPUTS_STATUS}}
* CRT Adjust (H-Position, V-Shift, H-Size, V-Size): {{CRT_ADJUST_STATUS}}
* HDMI scaling (integer scale, crop, crop offset): {{SCALING_STATUS}}
* HDMI rotation (orientation): {{ROTATION_STATUS}}
* Flip screen, HDMI and analog, from the OSD or the DIP (fake DIP where the game has none): {{FLIP_STATUS}}
* HDMI-only options hidden under direct video: {{DIRECT_VIDEO_STATUS}}
* Peripheral menus shown only for games that use them: {{PERIPHERAL_MENUS_STATUS}}
* Rotary joysticks (Ikari Warriors controls, GRS keystroke mode), where used: {{ROTARY_STATUS}}
* Light guns: mouse, analog stick and synthetic crosshair, where used: {{GUN_STATUS}}
* Audio mix (Mono, None, 25%, 50%): {{AUDIO_MIX_STATUS}}
* Hiscore saving (`hiscore.v`, with autosave): {{HISCORE_STATUS}}
* NVRAM / EEPROM saved to the `.nvm` file: {{NVRAM_STATUS}}
* Fast ROM loading via DDR: {{DDR_LOAD_STATUS}}
* Pause (with CPU suspended): {{PAUSE_STATUS}}
* Sound: {{SOUND_STATUS}}
* Savestates (optional): {{SAVESTATE_STATUS}}
* Cheats (optional): {{CHEATS_STATUS}}

### Todo

- [ ] {{TODO_ITEM}}

### Resource usage

{{WHICH_BUILD}} on the DE10-nano's Cyclone V 5CSEBA6, speed grade 7, {{TIMING_ONE_LINE}}:

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | {{ALMS}} | 41,910 |
| Block memory bits | {{BITS}} | 5,662,720 |
| RAM blocks | {{M10K}} | 553 |
| DSP blocks | {{DSP}} | 112 |
| PLLs | {{PLLS}} | 6 |

<!-- Name the commit and the revision the numbers came from. One line on which resource is the
     one to watch. -->

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant. {{AUTHOR_FAMILIARITY}}

## Verification

Not PCB-validated. MAME is the accuracy reference, with its own acknowledged uncertainties noted
where they matter.

* {{VERIFICATION_BULLET}}
<!-- One bullet per thing that was diffed against MAME, with the count: CPU trace (N accesses),
     video frames (N pixels of N), SDRAM image readback, .mra byte-for-byte against ROM_START,
     sound against a transcription of MAME's mixer. Numbers, not adjectives. -->

## Acknowledgements

- **Sorgelig** and the **MiSTer-devel team** for the
  [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) framework{{SDRAM_CREDIT}}.
- The **MAMEdev team** — {{DRIVER_AUTHORS}} — for `{{MAME_DRIVER}}` and the device emulations that
  are this core's specification.
{{VENDORED_MODULE_CREDITS}}
<!-- One line per upstream in THIRD-PARTY.md: author, what was taken, link. -->

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

{{LICENCE}} (see `LICENSE`). Imported components keep their own licences; `THIRD-PARTY.md` has the
detail and every modified vendored file states the change in its header.

Game ROMs contain copyrighted material and are not included. Obtaining them is your
responsibility.
