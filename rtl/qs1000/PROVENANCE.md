# rtl/qs1000 provenance

Both directories are copies of jotego's JT8051 (`jtcores`, `modules/jt8051`). Licence: the files carry
`SPDX-License-Identifier: GPL-3.0-or-later`, `Copyright 2026 Jose Tejada Gomez`; this repository is
GPL-3.0 (`LICENSE`).

- Upstream path: `E:/jtcores/modules/jt8051/hdl/` (local checkout of the jtcores repository).
- jtcores HEAD at the copy: `5e665515d1fe19e2f2562094ca666c2dbd1d9c96`. Last commit touching
  `modules/jt8051`: `ff1b8ffb795412d013ee9bbd18b877d52700ab26`. The module had no uncommitted changes.
- Generated files: the microcode includes are not in the upstream repository. They were generated with
  `jtframe` built from `modules/jtframe/src/jtframe` (same checkout, `go build`), run in the destination
  directory with `MODULES=<jtcores>/modules JTFRAME=<jtcores>/modules/jtframe JTROOT=<jtcores>
  CORES=<jtcores>/cores JTBIN=<jtcores>/bin`:
  `jtframe ucode jt8051 8051 --output jt8051` (`jt8051.vh`, `jt8051_param.vh`, `jt8051.uc`, from
  `modules/jt8051/ucode/8051.yaml`).

## `jt8051/` (reference, as upstream)

The six `hdl/*.v` files unchanged, plus the generated files. Local change: `jt8051.vh` reads
`rtl/qs1000/jt8051/jt8051.uc` instead of `jt8051.uc` (path relative to the repository root, where
Verilator runs).

## `jt8052/` (the sound CPU of the QS1000)

`jt8051` with every `jt8051` renamed `jt8052` (module names, include names), so both can be compiled
together, and these changes. The microcode is the same: `jt8052.vh` / `jt8052_param.vh` are the
`--output jt8052` output of the same command, and `jt8052.vh` reads `rtl/qs1000/jt8051/jt8051.uc`
(identical to what the generator writes as `jt8052.uc`; not duplicated).

1. `jt8052.v`, `jt8052_regs.v`: `ram_addr` is 8 bits (was 7). The firmware's stack starts at SP = 0xD8
   and it uses `@R0/@R1` above 0x7F; the 8052 has 256 bytes of internal RAM, of which 0x80-0xFF are
   reached only by indirect and stack accesses.
2. `jt8052_regs.v`: `sfr_sel` is `addr8[7] && !ind`. `ind` is set for a stack access, `EA_ADDR`
   (`@Ri` read) and `RI_DST` (`@Ri` write), cleared by the later overrides (`RN_DST`, `DIRECT_DST`,
   `EAW_DST`, `BIT_DST`, `BITC_DST`, `DIRECT_SRC`, `BIT_SRC`, `BITQ_SRC`). `EAW_DST` stays direct:
   its only user is `MOV direct,direct` (0x85), whose destination can be an SFR. With `ind`, 0x80-0xFF
   goes to RAM instead of the SFR file. `ram_addr` is `addr8` for `ind` accesses and `{0, addr8[6:0]}`
   otherwise.
3. `jt8052_regs.v`, SFR write block (`sp`, `dptr`, `psw`, `a`, `b`): the value is `sfr_din` (the
   merged byte) instead of `src`, and the write is skipped for a conditional bit instruction whose
   condition is false. Upstream writes `src`, which for a bit instruction is the single bit: `CLR ACC.7`
   with A = 3 leaves A = 0 (seen at instruction 815,745 of the `misncrft` trace). Same for `SETB/CLR/CPL`
   on ACC, B and PSW bits, and `JBC`.

4. `jt8052.v`: output `p3_we`, high for the enable period after a write to P3 (`sfr_we && sfr_addr ==
   8'hb0` registered on `cen`, so the user is not on the path through the ALU). The
   QS1000 acknowledges the sound latch on a P3 write with bit 5 low (`vamphalf.cpp qs1000_p3_w`), not
   while bit 5 is low; the port latch alone cannot tell a write from a held value. And `p3_latch`, the
   P3 SFR as written (`p3_o` gates bits 1:0 with the UART pins): the ROM bank is P3 bits 2:0.

Not implemented: Timer 2 (T2CON, T2MOD, RCAP2, TL2/TH2, IE.5, IP.5, vector 0x2B). Neither firmware
touches it; see `docs/QS1000_8052_FINDINGS.md`. The upstream testbenches under
`modules/jt8051/ver` are not run against `jt8052` (their runner `simunit.sh`, `as31` and `ruby` are
not installed here); `jt8051/` is untouched.
