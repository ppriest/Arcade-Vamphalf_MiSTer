# Shared simulation models

## `sdram_chip_model_wide.sv`

Vendored from `Arcade-Seta_MiSTer/sim/common/`, with one change (marked [GX]: `open_row` sized for four banks, since this core's image goes above 16 MB and Seta's never did), which had it from
Fuuki and before that Psikyo (a widened copy of Psikyo's `sdram_chip_model.sv`).
It decodes real SDRAM commands and models CAS latency and bursts rather than
being a latency stub; it uses the real 13-bit row width, so regions do not
alias. See the file's own header.
