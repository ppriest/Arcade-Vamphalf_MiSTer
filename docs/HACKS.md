# Hacks, approximations and workarounds in this core

Everything in this core's own RTL, scripts or `.mra` layout that is known not to be what the
hardware does: a stand-in, a shortcut, a value chosen to make something work, a workaround for a
tool. Each entry is added in the commit that introduces the hack and removed in the commit that
removes it.

This is not `MAME_KLUDGES.md`. That file lists MAME's own guesses that the core reproduces on
purpose because MAME is the reference. This file lists what is ours.

Rules:

- An entry cites `file:line` (or a module and signal name if the line moves often), and the
  evidence column says what was measured, or "unverified".
- "What would make it correct" names the work, not "fix later".
- A hack whose entry is missing is a bug. A hack whose entry is stale is worse: update it in the
  same commit as the code.
- Severity is what a player or a verifier would see: **visible** (wrong pixels, wrong sound, wrong
  timing a game can hit), **latent** (wrong only for input no in-scope set produces), **tooling**
  (affects the build or the bench, not the bitstream).

| What | Where | Why it is a hack | What would make it correct | Evidence | Severity |
|---|---|---|---|---|---|
| Timer interrupt fires once when TR reaches TCR, from the clock after (`timer_hit`); TR counts a `tick` pulse input at the CPU's rate (50 MHz; aoh 80 MHz with `tick2`), not the RTL's own cycles | `rtl/e1/e1_cpu.sv` `timer_eval`, tick block | MAME arms one timer per TCR/FCR/TR write; the RTL re-evaluates on those writes and on each TR increment. The E1 bench ties `tick` low, so TR is not compared | Replay a trace that takes a timer interrupt; compare TR against MAME's | Mission Craft takes it in play: MAME enters its vector (0x20) 60 times in 60 frames of play (`scripts/mame/tracewin.lua`, frames 900-960 after a coin; the Eolith core's session counted 927 in 598 frames). The RTL's timing of it is not compared with MAME's | timing |
| Boong-Ga Boong-Ga's hit strength: four pad buttons give the photo sensors' 1st, 3rd, 5th and 7th strengths (5-7, 11-13, 17-19 and 23-25 points) | `rtl/vh_main.sv` `bg_hit` | MAME has seven strengths (`boonggab_photo_sensors_r`) and its TODO asks for a "stroke strength" model of the real sensors | A seven-button J1 line, or an analog strength from a trigger | Not checked against the cabinet | visible |
| `retire_pc` of a TRAP is the halfword after it | `rtl/e1/e1_cpu.sv` (the retire record) | Debug output only; execution is right. Seen by the Eolith core's sys_tb on crazywar (TRAP 37 at 0xfffffd1c retired as 0xfffffd1e), which accepts PC+2 for opcodes from 0xfc00 | The trap's own address in the retire record | Not checked in this core's benches, which compare the next PC | tooling |
| Power-down and sleep are not modelled | `rtl/e1/e1_cpu.sv` | MAME's `powerdown` flag is not reproduced | Implement `m_core->powerdown` if a set uses it | Not seen | latent |
| Instruction fetches outside work RAM, program ROM, the upper sprite RAM and the internal RAM read 0 | `rtl/vh_cpumem.sv` `if_data` | MAME fetches from wherever PC points, sprite RAM and palette included; the instruction port reads only the I-cache and the internal RAM | A fetch path to the video RAMs and I/O through the data side | No game's PC leaves those regions in the traces checked (`sim/ref/<set>`, 1,000,000 instructions per set) | latent |
| Flip captures poke the flip I/O port from Lua | `scripts/mame/vcap.lua` `VC_POKE`, `scripts/vamphalf_capture.py --poke` | Neither set has a flip DIP or menu entry and the games write the flip port once at boot (value 0), so a flipped frame is the unflipped game state rendered with the flipped band order, not a game laid out for flip | A game state that sets flip itself (cocktail setting) | The model matches MAME on all 11 captures per set that were taken with flip set (`sim/ref/<set>/video/manifest.txt`) | tooling |
| Play stimulus repeats the coin every 97 frames and Start every 211 frames | `scripts/mame/vcap.lua`, `scripts/mame/wtiming.lua`, `scripts/mame/regions.json` "inputs" | A single coin pulse (1, 3, 20, 60 frames) was not credited in either set; cause not looked into | Find why a single pulse fails | Snapshots show CREDIT 9 and play from frame 600 (`debug/wtiming/snap_play/`) | tooling |
| The first frame after a flip change is drawn with the new clip; MAME draws it with the previous update's | `rtl/video/vh_video.sv` `flip_l` | MAME_KLUDGES.md Video 1: MAME's visible area changes inside screen_update, leaving 4 stale lines for one frame | Model the previous-update clip and a persistent bitmap | Not exercised: no in-scope game sets flip | latent |
| Sprite-list snapshot starts after the CPU's write to the last dword of band 15 and only between lines 252 and 8 | `rtl/video/vh_video.sv` `list_ready`, `in_copy_window` | The real board's latch point is unknown (no evidence); MAME draws from live RAM at vblank start | Measure the RTL CPU's pass length against the window on hardware | MAME sweep: the pass runs lines 252..259 in 1800/1800 frames of three of four runs | visible if the RTL CPU's pass overruns line 8 |
| Age Of Heroes' sprite-list snapshot is taken at line 240, the start of the vertical blank, before the game's list pass: the picture shows the list one frame later than MAME | `rtl/video/vh_video.sv` `list_ready` (`aoh`) | MAME draws at line 240 from sprite RAM written in the pass before (`screen_update_aoh`, no buffer); the core renders the next frame from a snapshot, so the list MAME shows is only complete after the pass (lines 240..247 in MAME's sweep). A snapshot after the pass (line 250) tore whenever the RTL CPU had not finished it, seen on the board as tearing when the screen scrolls vertically | A CPU that finishes the pass by line 250 (MAME's E1 timing), with the snapshot back after the pass | MAME sweep: first write at line 240 in 1799 of 1800 frames of play, last by line 247 (`debug/aoh_wt_play.txt`); `sim/sys_tb +swlog`, 900 frames of play: snapshots torn by a write after the copy began, at line 250, 845 of 888 vertical blanks with `e1_cpu` and 33 of 890 with `e1_pipe`; at line 240 (`e1_pipe`), a write ahead of the copy while it ran in 2 of 890, frames whose pass ran outside lines 240..250 (passes ended 32, 117 and 263 lines after vblank start) | visible (one frame of lag against MAME) |
| Palette is read live by the scan-out | `rtl/video/vh_video.sv` `u_pal` | MAME's palette writes fall on lines 259..263 and 0..2 only | A snapshot if hardware shows writes in active display | Write sweep | latent |
| The E1 runs unthrottled on clk_sys (56 MHz) at the RTL's own clocks per instruction, behind caches; only its timer counts at 50 MHz (`cpu_tick`) | `rtl/vh_main.sv` `u_cpu` `.cen(1'b1)`, `Vamphalf.sv` `cpu_tick` | The RTL averages 3-9 clocks an instruction (sim/sys_tb) where the chip takes about 1-2; MAME's own E1 timing is marked "probably incorrect" (`vamphalf.cpp:1143`) | A measured instruction rate of the real board | Both games wait for vblank in an idle loop (PC 0xff5a on Mission Craft, MAME's speed-up address); sim/sys_tb runs 130k instructions a frame there with the idle loop included | visible if a game's frame work outgrows the frame |
| The sound output is the mean of 16 engine ticks, 46.875 kHz | `rtl/qs1000/vh_qs1000_voice.sv` `out_l/out_r` | MAME's engine runs at 750 kHz and its mixer resamples to the host rate; the chip's own output filter and DAC rate are not documented | The QS1000's DAC rate and output filter from a datasheet or a recording | `scripts/qs1000_model.py --wav` uses the same box filter; its RMS against MAME's `-wavwrite` is 1.000 (misncrft) | visible (audible: the box filter's response above about 10 kHz) |
| The SUPLUP board (suplup, luplup, luplup29, luplup10, puzlbang, puzlbanga) runs at the core's 7 MHz pixel clock, not 14.318181 MHz / 2 = 7.159 MHz: 59.19 Hz instead of 60.53 Hz, 2.2% slow | `rtl/video/vh_video.sv` timing (8 clk_sys per pixel) | `CLAUDE.md`: clk_sys is an integer multiple of the pixel clock; 56 MHz / 7.159 MHz is 7.82 | A clk_sys that both pixel clocks divide, or a per-set PLL setting | `suplup()`, `vamphalf.cpp:1251`; the sound chips keep their 14.318181 MHz clocks (`vh_ymoki` `xtal14`), so pitch is MAME's | visible (2.2% slower game and music tempo) |
| The 8052's P0, P2 and P3 pins read 0xff | `rtl/qs1000/vh_qs1000.sv` `vh_qs1000_mcu` `p0_i/p2_i/p3_i` | MAME's `p0_r` returns 0xff; P2 and P3 have no input callback in `vamphalf.cpp` | What the board ties those pins to | Neither firmware reads P2 or the P3 pins in 3,000,000 traced instructions (P3 reads are read-modify-write, which read the latch) | latent |
| Wivern Wings' 0x1800 protection: a dword write is fed to the seed as the high half, then the low half | `rtl/vh_main.sv` `prot_wr2` | A 16-bit handler on the 32-bit bus with no umask is called once per half by MAME's memory system (`emumem_heu.cpp` sorts the subunits by offset); how the game writes the port is not in any trace | A MAME trace of the hour-mark check (the port is first written about an hour in) | Unverified | latent until about an hour of play |
| Mission Craft's buttons are named Button 1-4 in the `.mra` | `scripts/build_mra.py` `BUTTONS` | history.xml gives 4 buttons and no names | The game's own instruction screen or manual | `validate_mra.py` passes it only with `--allow-generic-buttons` | tooling |

<!-- Examples of the shape, from sibling cores:
| Sound mailbox is a stub that answers the power-on test | `rtl/gx_snd_stub.sv` | No sound CPU yet; the stub returns the reply the test expects and a heartbeat | Phase 3: the real sound board | The game's RAM check passes with it; nothing else is exercised | visible |
| Sound-command spin of 800 CPU clocks after a latch write | `rtl/cpu/…_bus.sv:NNN` | Copies MAME's 40 us wait; the real board's mechanism is unknown | A measurement of the latch on hardware | Without it the second byte overwrote the first (commit) | latent |
| Sound CPU reset held 1,024 clocks | `rtl/….sv:NNN` | MAME's pulse is zero-length; the T80 needs to see it | The measured reset length | A PCB measurement says about one second | latent |
| Screen timing from one game used for every game | `rtl/video/…crtc.sv` | MAME declares 60 Hz with no comment; the one PCB-verified rate is used for all | Per-game timing from PCB measurement | 0.043% from the verified rate | visible |
-->

## Removed

Entries move here when the hack is gone, with the commit that removed it, so a later reader can
tell "never had it" from "had it and fixed it". Delete a row once nothing else refers to it.

| What | Removed by | Replaced with |
|---|---|---|
| Sprite RAM backs 64 KB of the 256 KB window; reads above it are not served | Phase 2 top level (`rtl/vh_cpumem.sv` `r_sprh`) | 0x40010000-0x4003ffff in SDRAM (`SD_SPRHI`) through the caches: Mission Craft's power-on test walks the whole 256 KB and failed at 0x40010000 on the 64 KB alias (sim/sys_tb) |
