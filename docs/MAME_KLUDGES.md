# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
software model and the RTL reproduce MAME's guesses on purpose. This file lists each one that
touches an in-scope set: where it is in MAME, what the core does, and what would settle the real
behaviour.

It also records where a vendored, silicon-derived module disagrees with MAME and the module was
kept (ROADMAP, "Where a vendored module and MAME disagree").

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `E:/mame/src/mame/misc/vamphalf.cpp` unless named. The installed binary is
MAME 0.289; the tree is the local back-port named in `HARDWARE_NOTES.md`.

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope);
*not checked*. "Model" is `scripts/render_model.py`; its match against MAME is 342 of 342
captured frames pixel-identical on `misncrft` and on `wivernwg` (`sim/ref/<set>/video/manifest.txt`).

Neither in-scope set is flagged MACHINE_IMPERFECT_GRAPHICS.

## Video

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| Flip moves the visible area from lines 16..251 to 20..255 | `:862-877`, comment `:864` "are there actually registers to handle this?"; `:44-49` says the Semicom boards never output 4 lines, confirmed on hardware (unflipped case only) | model copies (`visarea()`) | A flipped PCB capture; no in-scope game ever sets flip (flip port written once, value 0, through frame 5600 in both sets) |
| The visible area is changed inside `screen_update`, so a frame is drawn with the area the previous update left; only the clip is cleared (`bitmap.fill(0, cliprect)`), so rows outside it keep what an earlier update drew there | `:880-885` calls `handle_flipped_visible_area` (`:882`) first, then fills and draws with the `cliprect` it was passed | model copies (`clip_flip`, persistent bitmap). First update after flip 0 to 1: rows 252..255 of the snapshot were never drawn (pen 0); after flip 1 to 0: rows 16..19 hold what the first flipped update drew there. Wrong by 1280 px (4 lines x 320) without it; 0 with it, frames 3501/3901 (`misncrft_attract`), 4701/5401 (`misncrft_play`) and the wivernwg equivalents | A transient of one frame, seen only if flip changes; the RTL need not reproduce it |
| The 93C46 writes and erases in 1 us (MAME's default 1.75 ms / 1 ms); write-all and erase-all keep 8 ms | `common()` `:1145-1147`, comment "various games require fast timing to save settings, probably because our Hyperstone core timings are incorrect" | RTL copies (`rtl/vh_main.sv` `u_ee` `WRITE_US(1)`, `ERASE_US(1)`) | The part's real busy time (about 1-2 ms for a 93C46) with an E1 that runs at the board's instruction rate |
| Flip: x = 366 - x, y = 256 - y, both flips toggled, band = y/16 instead of 16 - y/16 | `:739-748`, `:775-781` | model copies; matches MAME on the flip captures, which were made by poking the flip port (sprite RAM was laid out for the unflipped case) | The unflipped frame turned 180 degrees from a game that lays its list out for flip (WORKFLOW, flip check): none of the two sets does |
| Only bands 1..15 are read (0x0800..0x7fff of the 0x40000-byte sprite RAM); bands 0 and 16 and everything from 0x8800 are never read | `:733-740`: strips run `cliprect.min_y & ~15` to `max_y \| 15` = 16..255 in both visible areas, band = 16 - y/16 or y/16 | model copies. The games write band 0 (308/393 non-zero words, misncrft/wivernwg) and, on wivernwg, the first 16 bytes of band 16; 23 words from 0xc000 up are static in 342 of 342 frames | - |
| Pen 0 is transparent and the cleared bitmap shows palette entry 0, not black | `:882` fills pen 0; `gfx->transpen(..., 0)` skips raw pen 0 | model copies. Palette entry 0 is non-zero in the captures (wivernwg 0x7fff behind the Semicom logo, frame 300; misncrft 0x318c, frame 300) and the snapshot shows it | Board behaviour of colour 0 |
| xRGB_555: bit 15 ignored, each 5-bit channel expanded with `pal5bit` | `:1154`, `emupal.cpp` | model copies. 3087 palette words with bit 15 set in the misncrft captures, 0 mismatches | The board's DAC wiring |
| Sprite code taken modulo the number of 256-byte elements in the region | `drawgfx.cpp:354-549` (`code %= elements()`) | model copies (`code % elements`). Not exercised: largest code 14567 of 32768 (misncrft) and 64268 of 65536 (wivernwg) | A game that uses a code beyond the ROM |
| X is 9 bits, no wrap; sprites partly or wholly outside the visible area are clipped, not wrapped | `:769` | model copies. Not exercised beyond the visible area: x range in the captures stays within 0..350 | A capture with sprites past x = 351 |
| The picture is drawn from the sprite RAM and palette as they stand at the start of vblank (line 252), before the E1's vblank IRQ | `emu/screen.cpp:1149` (`vblank_begin` calls `update_if_primary` unless `VIDEO_UPDATE_AFTER_VBLANK`; the driver does not set it) | model: the list in force at vblank start; the game writes its whole list in lines 252..259 after that point (`docs/write_timing_mame.txt`) | Whether the board reads sprite RAM live during active display; no evidence |

## Sound

The QS1000 engine (`rtl/qs1000/vh_qs1000_voice.sv`) equals `scripts/qs1000_model.py`, a transcription of
`devices/sound/qs1000.cpp`, on every tick of the captures; the model equals MAME's `-wavwrite` (correlation
0.9999, RMS ratio 1.000).

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| No envelopes, no filter | `qs1000.cpp:115-125` (TODO) | copies | A PCB recording, or the QS1000 datasheet |
| No pitch bend: register 4 is ignored | `qs1000.cpp:115-125` (TODO) | **differs**: [204] bends the voice's rate, bit 7 up, bits 6-0 the magnitude v: x (1 + v/128) up, x (1 - v/256) down (`vh_qs1000_voice.sv` `bendmul`, `fe_mem`; `qs1000_model.py`), with `loop_pcb` (the cores); the benches keep MAME's. Evidence (Arcade-Eolith_MiSTer `docs/QS1000_FEATURES.md`): up, Hidden Catch's PCB recording (youtube.com/watch?v=eNncNAm6a0A), the title tune's two bends held at +16 match at +195 cents (z 3.1, 3.2; the rule: +204); down, the Serdaco Qwave's recording of Descent's Level 1 through Hidden Catch 3's firmware, -24 to -2 at 6.8 cents a step (the rule's rms error 6.4 cents; 1/8 semitone's 84) | More upward values; the upward rule rests on one |
| A voice stops at its loop end instead of looping; key-off does nothing | `qs1000.cpp:444`, `:465`, `:494` (`#if 0 // Looping disabled until envelopes work`), `:385-386` (key-off clears a flag nothing reads) | **differs**: a voice at its loop end goes back to its loop start, ADPCM with the decoder state it had there (MAME's disabled save/restore), and key-off fades it out, one rate for every sample (HACKS.md); in the core (`Vamphalf.sv`, `Limenko.sv` `.loop_pcb(1'b1)`), the benches keep MAME's (`+loop=`, `qs1000_model.py --loop`). Evidence: the same Mission Craft recording, aligned with MAME's register writes at three points (Arcade-Eolith_MiSTer `docs/QS1000_FEATURES.md`, Recording, `scripts/qs1000_pcb_evidence.py`): notes still keyed after MAME's stop are in the recording at their pitch (+1.75 to +1.96 dB against a semitone-sharp copy, 83% of 5 s blocks positive); notes keyed off in their first pass carry on and fade over 200-400 ms | The release rates per sample: descriptor bytes 9-13 differ between samples whose fades differ |
| Register 6 is the left volume, 7 the right | `qs1000.cpp:432-434` | **differs**: [207] left, [206] right (`vh_qs1000_voice.sv`, `qs1000_model.py`). From the firmware reading the user shared, and three General MIDI files recorded on an LG MIDI ART GS1000R (wavetable.nl) played through Hidden Catch 3's QS1000 firmware in Arcade-Eolith_MiSTer's `sim/snd_tb`: each sound's left-right level difference against the recording's correlates -0.386, -0.287, -0.115 with MAME's mapping (Canyon, Doom E1M1, E1M8; Arcade-Eolith_MiSTer `docs/QS1000_FEATURES.md`, MIDI recordings) | - |
| ADPCM is OKI's: a 12-bit signal, 49 steps, saturating | `qs1000.cpp` (`oki_adpcm_state`), `:479` | **differs**: IMA's, 89 steps, a 16-bit signal that wraps, high nibble first, the output its top 8 bits (`vh_qs1000_voice.sv`; `qs1000_model.py --adpcm oki` keeps MAME's). From a firmware reading the user shared; checked on Mission Craft's 10 music samples: median DC 0.004 of RMS against OKI's 0.508, the most tonal decode for 8 of 10 (Arcade-Eolith_MiSTer `docs/QS1000_FEATURES.md`, A firmware reading) | The QS1000's internal program ROM, or a recording of a known MIDI file |
| Volume registers 6, 7 and 8 scale the sample linearly; ADPCM is OKI's, the 12-bit signal cut to 8 bits and times 4; PCM times 1 | `qs1000.cpp:432-434` (volumes), `:479`, `:484-485`, `:513-514` | **differs**: with OKI decoding ADPCM x2, PCM x4 (PCM 18 dB higher against ADPCM than MAME); with IMA, whose music is 12.9 dB lower at the same gain (Mission Craft 10-160 s, RMS 0.0439 against OKI's 0.1946), ADPCM x8, PCM x4, the music within 0.9 dB of OKI's x2; fixed in the core (`Vamphalf.sv`, `Limenko.sv` `.bal_pcb(1'b1)`); the benches keep MAME's x4, x1 for their comparisons (`+bal=`, `qs1000_model.py --balance`). Evidence: a PCB recording of Mission Craft (youtube.com/watch?v=ur5dur6w9L4, `debug/pcb/`, 1188 s). Mission Craft's music is ADPCM (32 of 32 table entries in stage-1 play), its shot and the other effects PCM. The shot, located by a matched filter on MAME's rendering (`scripts/qs1000_stems.py`), peaks at a median -2.9 dB of the recording's RMS (range -5.5 to -1.9 over 18 one-minute windows, average-to-template correlation 0.41-0.43, random positions 0.02-0.04, shots every 169 ms); MAME's balance gives -20.3 dB. The same estimator on MAME's stems mixed at known gains reads within 0.6 dB from +10 dB up: +18 dB predicts about -2.6 dB. MAME's music also clipped (peak 40939 at /4096); at x2 it peaks near 20500 | A recording of a game whose effects are ADPCM, or of Wivern Wings |

## CPU and I/O

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| SETADR (SET with N = 0) ORs the wrap carry into bit 0 instead of adding 512 | `src/devices/cpu/e132xs/e132xsop.hxx` `hyperstone_set`: `(SP & 0xfffffe00) \| (GET_FP << 2) \| (((SP & 0x100) && (SIGN_BIT(SR) == 0)) ? 1 : 0)`; the DRC (`e132xsdrc_ops.hxx:3563-3574`) the same. MAME's original `src/emu/cpu/e132xs/e132xs.c` has the comment "plus carry into bit 9" above `val += ... ? 1 : 0` | **differs**: the carry goes into bit 9 (`rtl/e1/e1_cpu.sv`, SET); `sim/e1_tb` accepts exactly this difference and continues from MAME's value (3 of the 52 conformance seeds hit it). With MAME's version `mrkickera` hangs whenever it rewrites its EEPROM beyond words 0-1: its scheduler saves a task's stack address with SETADR; when the task's frame has wrapped (FP 4, SP 0x78d78) the address is 0x78c11 instead of 0x78e10, the task resumes on the wrong stack and returns to 0, and the OS idles for good with the erased word left at 0xffff (`scripts/mame/bplog.lua` registers; `debug/eeprom/`). Adding 0x200 instead, the core rebuilds the EEPROM from blank and boots (sys_tb: 33 words written by frame 325, each equal to the ROM default's; attract mode at frame 879), and the 1,000,000-instruction traces of the other eight traced sets are unchanged. The same fault is MAME's `royalpk2` TODO (`f32/f-32.cpp`: it soft-locks on a settings save in the service menu): built with the fix (`E:/mame-setadr/f32.exe`), Save shows "Saving... Good" and the menu still moves; without it the PC stays at 0x1928 from then on (`scripts/mame_drive.py`, `debug/rp2/`) | The Hyperstone manual's SETADR definition; `mrkickera` on a PCB with a blank EEPROM |
| `finalgdr` has no flip-screen register | `finalgdr_io` comments out `map(0x1820, 0x1820).w(...flipscreen32_w); //?` and `init_finalgdr` sets `m_flip_bit = 1; //?` | copies: the game cannot flip the picture; the OSD's Flip Screen still does | A PCB write to I/O 0x1820, or the game's test mode offering flip |
| `boonggab`'s photo-sensor field reads 0 at rest | `PORT_BIT(0x3800, IP_ACTIVE_LOW, IPT_CUSTOM) PORT_CUSTOM_MEMBER(boonggab_photo_sensors_r)`: the callback returns 7 for no hit, and the active-low field is inverted on read (`ioport.cpp:1595`), so the game reads 0 (P1_P2 0xc7ff) | **differs**: the core gives the callback's value, 7 at rest (`rtl/vh_main.sv` `bg_hit`). With MAME's 0 the game's Setup main menu selects its first item every frame, so Right in the Test menu (back to the Setup main menu) returns straight to it (`scripts/mame_drive.py`, a 1-frame tap: Setup main menu at frame 905, Test menu at 920). With the field at 7 (MAME with P1 Button 7 held) the Setup main menu holds and Right selects; coin, start and play work either way | A PCB read of P1_P2 at rest |
| `mrkickera`'s SemiCom stream values are finalgdr's (2 and 3) | `init_mrkickera` sets `m_semicom_prot_data` as `init_finalgdr` does | copies | A PCB read of I/O 0x1900 after each key written to 0x1010 |
| A read of the EEPROM output port (I/O 0x1000 on `mrkickera`) returns 0 | `mrkickera_io` `map(0x1000, 0x1000).nopr(); //?` | copies. The game reads it back into its copy of the port (32 reads at boot) but builds every write from its own cached value, so the EEPROM traffic does not depend on it | What the PCB returns |

## Capture tooling (not MAME kludges, recorded because they decide how the references were made)

- `-snapview native` snapshots of `wivernwg` (ROT270) are the model's bitmap turned 180 degrees;
  `misncrft` (ROT90) is not turned. `render_model.py compare` measures it on the first frame and pins it.
- A single coin pulse is not credited by either set; repeated pulses from frame 400 are
  (`scripts/mame/vcap.lua`). Neither set has a flip DIP or a flip entry reachable without play, so the
  flip captures poke the flip I/O port (HACKS.md).

## Vendored modules that disagree with MAME

| Module | MAME | Kept because | Evidence |
|---|---|---|---|
| jt51's busy flag (`rtl/sound/jt51/hdl/jt51_mmr.v`, 32 synth clocks after a data write) clears sooner than MAME's YM2151 (ymfm) | `vamphalf` polls the status port (0x51) after each write: MAME reads it busy about 57 times per write in its boot (1,320 busy, 23 ready reads in the first 1,000,000 instructions, `sim/ref/vamphalf`) | jt51 follows the chip's documented 32-cycle busy; the game only waits on it, so only the number of polls changes | `sim/sys_tb` `vamphalf` agrees with MAME's trace for 893,119 instructions, to the first poll whose count differs |
