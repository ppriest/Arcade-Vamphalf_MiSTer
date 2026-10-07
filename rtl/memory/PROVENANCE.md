# `rtl/memory` provenance

| File | Source | Changes |
|---|---|---|
| `sdram.sv` | `Arcade-KonamiGX_MiSTer/rtl/memory/sdram/sdram.sv` at `b3a0827` (Sorgelig's `sdram.v`, GPL-3.0-or-later, extended to burst-4 by Psikyo, 26-bit by Fuuki, double read on port 0 by GX; the chain is in that file's PROVENANCE.md) | `[VH]`: the double read on ports 1 and 2 as well (`dbl1`/`dout1b`, `dbl2`/`dout2b`): the CPU's cache line and the QS1000's sample line are 16 bytes. `RFS_INTERVAL` parameter in place of the literal 335: at 56 MHz a chip needs a refresh every 437 clocks, and refreshes alternate between the 128 MB module's two chips, so the top passes 218 |
| `sdram_upstream_reference.sv` | same tree, unmodified | reference for diffing |
| `sdram_download.sv` | `Arcade-KonamiGX_MiSTer/rtl/memory/sdram_download.sv` at `b3a0827` | none |

`../vh_eeprom93c46.v` is `Arcade-KonamiGX_MiSTer/rtl/gx_eeprom93c46.v` at `b3a0827` with the save-state
ports removed; the MAME behaviour it models (states, busy times, lock) is unchanged.

`sim/common/sdram_chip_model_wide.sv` is the GX copy at `b3a0827`, unmodified (`sim/common/PROVENANCE.md`).
