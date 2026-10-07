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
| Timer interrupt fires once when TR reaches TCR; TR counts a `tick` pulse input, not CPU cycles | `rtl/e1/e1_cpu.sv` `timer_eval`, tick block | MAME arms one timer per TCR/FCR/TR write; the RTL re-evaluates on those writes and on each TR increment. Bench ties `tick` low, so TR is not compared | Replay a trace that takes a timer interrupt; compare TR against MAME's | Unverified: no timer interrupt in the first 1,000,000 misncrft instructions | latent |
| Power-down and sleep are not modelled | `rtl/e1/e1_cpu.sv` | MAME's `powerdown` flag is not reproduced | Implement `m_core->powerdown` if a set uses it | Not seen | latent |
| Flip captures poke the flip I/O port from Lua | `scripts/mame/vcap.lua` `VC_POKE`, `scripts/vamphalf_capture.py --poke` | Neither set has a flip DIP or menu entry and the games write the flip port once at boot (value 0), so a flipped frame is the unflipped game state rendered with the flipped band order, not a game laid out for flip | A game state that sets flip itself (cocktail setting) | The model matches MAME on all 11 captures per set that were taken with flip set (`sim/ref/<set>/video/manifest.txt`) | tooling |
| Play stimulus repeats the coin every 97 frames and Start every 211 frames | `scripts/mame/vcap.lua`, `scripts/mame/wtiming.lua`, `scripts/mame/regions.json` "inputs" | A single coin pulse (1, 3, 20, 60 frames) was not credited in either set; cause not looked into | Find why a single pulse fails | Snapshots show CREDIT 9 and play from frame 600 (`debug/wtiming/snap_play/`) | tooling |
| The first frame after a flip change is drawn with the new clip; MAME draws it with the previous update's | `rtl/video/vh_video.sv` `flip_l` | MAME_KLUDGES.md Video 1: MAME's visible area changes inside screen_update, leaving 4 stale lines for one frame | Model the previous-update clip and a persistent bitmap | Not exercised: no in-scope game sets flip | latent |
| Sprite-list snapshot starts after the CPU's write to the last dword of band 15 and only between lines 252 and 8 | `rtl/video/vh_video.sv` `list_ready`, `in_copy_window` | The real board's latch point is unknown (no evidence); MAME draws from live RAM at vblank start | Measure the RTL CPU's pass length against the window on hardware | MAME sweep: the pass runs lines 252..259 in 1800/1800 frames of three of four runs | visible if the RTL CPU's pass overruns line 8 |
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
