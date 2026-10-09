// The SDRAM image: byte addresses. The ROM download (ioctl index 0) writes the .mra's image at these
// offsets; scripts/build_mra.py reads the SD_* localparams from this file, so the two cannot drift.
//
//   SD_MAINCPU  1 MB      MAME "maincpu" (ROM_REGION16_BE / 32_BE: the CPU's byte order)
//   SD_SNDCPU   128 KB    "qs1000:cpu", the 8052 program, once (MAME reloads it four times)
//   SD_EEPROM   128 B     "eeprom", Mission Craft only: caught on the way in by the 93C46 model
//   SD_SAMPLES  5 MB      "qs1000" or "oki1", the region's start (the sets' data ends by 0x280000)
//   SD_PRGLO    1 MB      a 2 MB "maincpu"'s first MB (yorijori: 0xffe00000); SD_MAINCPU has its second
//   SD_GFX      16 MB     "gfx", MAME's region bytes in order (8 MB on Mission Craft)
//   SD_WRAM     2 MB      the CPU's work RAM, written at run time only
//   SD_SPRHI    192 KB    sprite RAM 0x40010000-0x4003ffff: only the power-on RAM test uses it, the
//                         video never reads it (vh_cpumem); run time only
// Everything below SD_WRAM is ROM.

localparam [26:0] SD_MAINCPU = 27'h0000000;
localparam [26:0] SD_SNDCPU  = 27'h0100000;
localparam [26:0] SD_EEPROM  = 27'h0180000;
localparam [26:0] SD_SAMPLES = 27'h0200000;
localparam [26:0] SD_PRGLO   = 27'h0700000;
localparam [26:0] SD_GFX     = 27'h0800000;
localparam [26:0] SD_WRAM    = 27'h1800000;
localparam [26:0] SD_SPRHI   = 27'h1a00000;
// Above the 32 MB line, for the one set that needs a larger module (boonggab: the 128 MB module):
//   SD_GFXHI    16 MB     "gfx" from 16 MB up (vh_gfxport)
localparam [26:0] SD_GFXHI   = 27'h2000000;
