// The Limenko SDRAM image (limenko.cpp): byte addresses. The ROM download writes the .mra's image at these
// offsets; scripts/build_mra_lm.py reads the LM_* localparams from this file.
//
//   LM_PRGLO    1 MB      "maincpu"'s first MB (0xffe00000), on the 2 MB programs
//   LM_MAINCPU  1 MB      "maincpu"'s last MB (0xfff00000); spotty's whole 1 MB program
//   LM_SNDCPU   512 KB    "qs1000:cpu", the 8052 program and its eight 64 KB data banks; spotty's
//                         AT89C4051 program (4 KB)
//   LM_EEPROM   128 B     the 93C46's power-on image: none of the sets has one, so 0xff (erased)
//   LM_SAMPLES  4 MB      "qs1000", the region's first 4 MB (no set loads above 0x400000); spotty's "oki"
//   LM_DATA     4 MB      "maindata" at 0x40000000; spotty: none (its "maindata" is the graphics source)
//   LM_WRAM     2 MB      the CPU's work RAM, written at run time only
//   LM_GFX      18 MB     "gfx", MAME's region bytes in order; spotty: its 4bpp graphics, two pixels a byte,
//                         the first in bits 3:0 (init_spotty's expansion, done by the video)
// Everything but LM_WRAM is ROM.

localparam [26:0] LM_PRGLO   = 27'h0000000;
localparam [26:0] LM_MAINCPU = 27'h0100000;
localparam [26:0] LM_SNDCPU  = 27'h0200000;
localparam [26:0] LM_EEPROM  = 27'h0280000;
localparam [26:0] LM_SAMPLES = 27'h0400000;
localparam [26:0] LM_DATA    = 27'h0800000;
localparam [26:0] LM_WRAM    = 27'h0c00000;
localparam [26:0] LM_GFX     = 27'h0e00000;
