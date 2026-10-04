# Vamphalf: hardware notes

Source: `E:/mame/src/mame/misc/vamphalf.cpp`, `vamphalf_prot.cpp/.h`, `devices/sound/qs1000.cpp`,
`devices/cpu/e132xs/`. Tree HEAD is `a2d0f76268e`, a local MiSTer back-port commit, not a MAME
tag; the installed binary reports `0.289`. Whether they agree is unchecked (roadmap, Open items).
Line numbers are from that tree. Everything is MAME's model unless marked.

Scope: Mission Craft (Sun, 2000) and Wivern Wings (SemiCom, 2001). The driver covers ~40 other
SemiCom/Dongsung boards on the same video hardware; out of scope for now.

## Sets

| Set | Game | CPU | Bus | Program ROM | GFX | 8052 code | Sample ROM |
|---|---|---|---|---|---|---|---|
| misncrft | Mission Craft 2.7 (parent) | GMS30C2116 | 16 | 512 KB at 0x80000 | 8 MB | 128 KB | 512 KB + 512 KB (qs1001a) |
| misncrfta | Mission Craft 2.4 | same | 16 | differs | same | same | same |
| wivernwg | Wivern Wings (parent) | E1-32T | 32 | 2 x 512 KB | 16 MB | 128 KB | 2 MB + 512 KB (qs1001a) |
| wyvernwg, wyvernwga | Wyvern Wings sets 1, 2 | E1-32T | 32 | differ | same CRCs as wivernwg | same | same |

All flagged `MACHINE_SUPPORTS_SAVE | MACHINE_UNEMULATED_PROTECTION`. ROM_START lines:
wivernwg 2430, wyvernwg 2456, wyvernwga 2482, misncrft 2551, misncrfta 2576; GAME lines 3446-3462.
Mission Craft rotates 90, Wivern Wings 270.

Loaded bytes: Mission Craft 0.5 + 8 + 0.125 + 1 = ~9.6 MB; Wivern Wings 1 + 16 + 0.125 + 2.5 =
~19.6 MB. Both fit a 32 MB module. The three Wivern Wings sets share GFX, `u7`, `romsnd.u15a`
and `qs1001a` by CRC (listing in the driver); only the program ROMs differ. `qs1001a` (CRC
d13c6407) is also common to Mission Craft. Mission Craft is the only one with an `eeprom` region
(128-byte default image per set).

Zips present in `F:/Emulation/roms/MAME ROMs`: `misncrft.zip`, `wivernwg.zip`.

## CPUs and chips

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|
| maincpu (misncrft) | GMS30C2116 (E1-16 class) | 50 MHz (`:1216`) | game, 16-bit external bus | none found |
| maincpu (wivernwg) | Hyperstone E1-32T | 50 MHz (`:1309`) | game, 32-bit external bus | none found |
| qs1000 | QS1000 + QS1001A ROM | 24 MHz (`:1195`) | all audio; 32-voice wavetable | none found |
| qs1000:cpu | 8052, external ROM | 24 MHz | command handler | jt8051 (no Timer 2) |
| fpga x2 | Actel A40MX04 | n/a | time-delayed protection | MAME lookup tables |
| eeprom | 93C46 16-bit | n/a | settings | jteeprom (jtcores) |

Searched for E1/Hyperstone RTL in the sibling cores, `E:/jtcores`, `E:/dev`, `E:/survey`,
`E:/MiSTer-MAME-Coverage`: nothing relevant. Two web searches (Hyperstone E1-32 FPGA core,
QS1000 FPGA) returned nothing relevant. Not exhaustive.

## Clocks

| Clock | Value | Source |
|---|---|---|
| CPU | 50 MHz | `:1139, 1216, 1309` |
| Pixel | 28 MHz / 4 = 7 MHz | `:1150` |
| Total / visible | 448 x 264 / 320 x 236 (HBEND 31, HBSTART 351, VBEND 16, VBSTART 252) | `:156-161` |
| Refresh | 7 MHz / (448 x 264) = 59.18 Hz | computed |
| QS1000 | 24 MHz; MAME stream rate clock/32 = 750 kHz | `qs1000.cpp:233` |
| 8052 | 24 MHz oscillator, 12 clocks per machine cycle | `qs1000.cpp:202` |

Unflipped visible area is 31..350 x 16..251, flipped 31..350 x 20..255 (`handle_flipped_visible_area`
`:862`; MAME comment "are there actually registers to handle this?").

## Interrupts

One source: vblank, `irq1_line_hold` (`:1141, 1219, 1312`). Vector and mask behaviour come from
the E1 core's interrupt logic; confirmed from the ROM in Phase 0.

## Memory map

Main CPU program space (`:477-491`):

| Range | What |
|---|---|
| 0x00000000-0x001fffff | 2 MB work RAM |
| 0x40000000-0x4003ffff | 256 KB sprite RAM |
| 0x80000000-0x8000ffff | palette RAM, xRGB555, 0x8000 entries (written through `palette_device::write16/32`) |
| 0xfff00000-0xffffffff | 1 MB program ROM |

I/O, Mission Craft (`misncrft_io`, `:513`): 0x040 flip (bit 0), 0x080 P1_P2, 0x090 SYSTEM,
0x0d0 protection read / 16-byte seed write, 0x0f0 EEPROM write (bit0 DI, bit1 CLK, bit2 CS),
0x100 sound latch (8-bit), 0x160 EEPROM read, 0x1a0 protection read / 8-byte seed write.

I/O, Wivern Wings (`wyvernwg_io`, `:555`): 0x0600 SemiCom 1-bit stream read / select write,
0x0800 flip (bit 0), 0x0a00 P1_P2, 0x0c00 SYSTEM, 0x1500 sound latch, 0x1800 FPGA protection,
0x1c00 EEPROM write, 0x1f00 EEPROM read.

MAME speed-up read handlers on idle loops (`init_misncrft` `:3141`, `init_wyvernwg` `:3219`)
are performance hacks, not hardware.

QS1000 side (`:1186-1201`, `:468`, `:3229`): the latch feeds 8052 P1 and raises INT1 when data is
pending; P3 low three bits select one of 16 banks of 0x7f00 bytes of `u7` into the 8052's data
space at 0x0100-0xffff; P3 bit 5 low acknowledges the latch.

## Video

One sprite layer, no tilemap, no scroll. `bitmap.fill(0)`, then sprites (`:729`).

- Sprite RAM is 17 bands of 0x800 bytes: 256 sprites of 8 bytes. The band for a 16-line strip is
  `(16 - y/16) * 0x800` unflipped, `(y/16) * 0x800` flipped. A strip draws only its band, clipped
  to the strip, in list order; later sprites overwrite earlier. That is a per-strip list, so a
  per-scanline engine fits.
- Sprite words: +0 low byte Y (screen y = 256 - Y), bit 8 hide, bit 15 flip X, bit 14 flip Y;
  +1 code; +2 colour in bits 6:0 (`m_palshift` = 0 for both games); +3 X in bits 8:0.
- Flipped: X = 366 - X, Y = 256 - Y, both flips toggled.
- `gfx_16x16x8_raw`: 16x16, 8 bpp, 0x80 colour groups of 256 colours = the 0x8000 palette; pen 0
  transparent. 16 MB = 65536 codes, 8 MB = 32768 codes.
- Not emulated per MAME: nothing flagged. The flip visible-area shift is a guess.

Worst case per scanline: 256 sprites per band; if all cross the line that is 256 x 16 pixel
writes. Sprite fetch is 16 bytes per sprite per line. The write sweep decides the latch point.

## Sound

`qs1000.cpp:11-125`: the 8052 takes commands over the latch and programs a register file at
0x200-0x211 of its data space. Key-on copies 16 channel registers; the engine reads a 6-byte
table entry, then a descriptor in ROM (start, loop start, loop end, PCM/ADPCM flag; 32 voices,
24-bit address). MAME plays PCM/ADPCM at a 18-bit-fraction rate with left/right/volume;
envelopes, filters, pitch bend and looping are TODO or `#if 0`. MAME's driver notes "sound dies
during stage 1-5" for misncrft (`:58`). The internal ROM of the QS1000 is undumped, so MAME
runs the external `u7` firmware.

## Protection

Two Actel FPGAs per board, modelled as lookup tables in `vamphalf_prot.cpp`.

- Mission Craft: seed write is `0xffff`, N bytes, `0xffff` at 0x1a0 (8 bytes, 7-entry table) or
  0x0d0 (16 bytes, 2-entry table). Result is 8 bits read back one bit per read, bit 7 first
  (`:60-70`). Entries depend on credits inserted. An unknown seed returns 0 and the game adds
  refresh hiccups after ~15 minutes (`:20-27`).
- Wivern Wings: 16-word seed at 0x1800, `0xffff` commit, 8-bit result read in parallel; 11 entries
  (credits 0..10, `wyvernwg_fpga_prot_device::seed_w`). Checked ~1 hour into play. MAME comment:
  "upper limit of credits count not really understood".
- Wivern Wings also has the SemiCom 1-bit stream at 0x0600 (`prot_r<0x0001>`, data {2, 1},
  `:3225-3227`).

The tables are MAME's; the board's behaviour on an unseen seed is unknown.

## Per-game configuration

| | Mission Craft | Wivern Wings |
|---|---|---|
| CPU | E1-16 class, 16-bit bus | E1-32, 32-bit bus |
| Program ROM | one 512 KB at 0x80000, rest 0x00 | 2 x 512 KB |
| GFX | 8 MB | 16 MB |
| Sample ROM | 512 KB + qs1001a | 2 MB + qs1001a |
| Protection | I/O 0x0d0, 0x1a0 | I/O 0x1800, 0x0600 |
| Rotation | 90 | 270 |
| EEPROM default | 128 B image per set | none |

## Feasibility

Two blocks have no RTL found anywhere:

1. **Hyperstone E1 CPU.** Write from MAME's interpreter (`e132xsop.hxx` 2770 lines,
   `e1defs.h`). 32-bit RISC, 64-entry register window, own ISA. Blocking unknowns: Fmax and CPI
   against 50 MHz (Phase 0 measurement); whether MAME's instruction timing is close enough for
   the games (the driver says MAME's Hyperstone timings are "probably incorrect", `:1143`).
   16-bit and 32-bit bus variants are one core in MAME.
2. **QS1000.** The 8052 is jt8051 plus whatever the `u7` firmware needs (Timer 2 and 256 bytes of
   internal RAM are absent from jt8051; whether the firmware uses them is not measured). The
   voice engine is address generator + ADPCM + mixer, with MAME's omissions (envelope, filter)
   as the open accuracy question.

Protection is two lookup tables. Video is one sprite layer.
