# QS1000 sound CPU on JT8051: findings

Phase 0, criterion 5. Firmware: `u7` of `wivernwg` (`u7`) and `misncrft` (`snd-rom2.us1`), 128 KB each,
MAME 0.289. Tools: `scripts/qs1000_static.py`, `scripts/mame_qs1000_trace.py`,
`scripts/qs1000_trace_stats.py`, bench `sim/qs1000_tb` (`docs/QS1000_TRACE_FORMAT.md`).

## What the firmware uses

Static (`python scripts/qs1000_static.py <u7.bin> --seed <set>_instr.trace`): reachable code is 1,879
(`misncrft`) and 1,878 (`wivernwg`) instructions, all in 0x0000-0x0DE4. Both firmwares run the same
code there. Without the trace seed 1,761 instructions are found; the rest is behind computed jumps.

| 8052-only item | Static, both sets | Dynamic, 3,000,000 instructions each |
|---|---|---|
| T2CON/T2MOD/RCAP2/TL2/TH2 direct access (SFR 0xC8-0xCD) | 0 | 0 SFR accesses at 0xC8-0xCD |
| T2CON bit access (0xC8-0xCF), IE.5 (0xAD), IP.5 (0xBD) | 0 | - |
| IE/IP written with bit 5 | 0; the only IE/IP writes are `mov ie,#0x86`, `mov ip,#0x04` at 0x002F, 0x0032 | IE = 0x86, IP = 0x04 throughout |
| code at vector 0x2B | none: 0x2B is the middle of the init code at 0x0024 (`b5 75 81`) | no PC at 0x2B |
| internal RAM 0x80-0xFF | `mov sp,#0xD8` at 0x002C; 183 `@Ri` instructions | see below |

Internal RAM at or above 0x80 (SFR rows excluded; `scripts/qs1000_trace_stats.py`):

| | `misncrft` | `wivernwg` |
|---|---|---|
| stack/call/ret/push/pop reads, writes | 69,640 / 69,458 | 46,747 / 46,447 |
| `@R0/@R1` reads, writes | 192,550 / 4,236 | 195,262 / 1,755 |
| distinct addresses | 106, from 0x80 to 0xEA | 106, from 0x80 to 0xEA |

Conclusion: Timer 2 is not used and its interrupt is never enabled, in either firmware, in the
executed code or in any reachable code. The 8052's upper 128 bytes of RAM are used: the stack starts at
0xD8, and indirect accesses reach 0x80-0xEA. A 128-byte core cannot run this firmware.

Other facts from the traces: SCON is written once (0x40, mode 1) and SBUF never, no serial interrupt
is enabled (IE.4 = 0): the serial port is unused in these runs. Timer 0 (mode 1) is the periodic
interrupt (T0 vector 0x0B), INT1 (edge) is the latch. Each 3,000,000-instruction run has 12 latch writes
and 12 INT1 entries; T0 entries: 84 (`misncrft`), 143 (`wivernwg`).
External data: RAM at 0x0000-0x00FF, wavetable register writes at 0x0200-0x0211 (1,563 and 408 in the
runs), ROM bank reads at 0x2000-0x53ff.

## Bench result

`scripts/run_verilator.sh qs1000_tb -GCORE=<0|1> +rom=<u7.hex> +instr=<set>_instr.trace
+bus=<set>_bus.trace +n=3000000`. The bench checks PC, A, B, PSW, SP, DPTR, R0-R7, IE, IP, TMOD,
TCON, TL0/TH0/TL1/TH1, the P1-P3 latches and the whole internal RAM after every instruction, and
every external data access.

| Core | `misncrft` | `wivernwg` |
|---|---|---|
| `jt8051` (`-GCORE=0`, unmodified, 128-byte RAM address) | stops at instruction 29 | stops at instruction 29 |
| `jt8052` (`-GCORE=1`) | 2,999,999 instructions, 0 mismatches, 96 interrupt entries, 25,264 external accesses | 2,999,999 instructions, 0 mismatches, 155 interrupt entries, 23,027 external accesses |

`jt8051` at instruction 29: the first `lcall` (0x006E) pushes its return address at 0xD9 and 0xDA; the
core treats addresses 0x80-0xFF of the stack as SFR accesses (`sfr_sel = addr8[7]`), the push goes
nowhere and the model's RAM at 0xD9 is 0 where MAME has 0x71.

Divergences found on the way, in order, with `jt8052`:

1. Instruction 815,745 (`misncrft`): `clr acc.7` with A = 3 cleared A. Upstream bug (see
   `rtl/qs1000/PROVENANCE.md`, change 3); upstream's vectors have no bit instruction on ACC, B or PSW.
2. Instruction 815,978: `mov b,0x26` wrote RAM 0xF0 instead of B. Own error in the first version of the
   upper-RAM change (`MOV direct,direct` uses the `EAW_DST` path); fixed.
3. Instruction 1,093,223: the first Timer 0 interrupt entry. MAME's pre-state of the vector
   instruction has TL0 = 0; the core has 2. MAME adds the two cycles of the vector sequence to
   the next instruction's timer update, the core counts them in the sequence. The timers match again
   at the next boundary; the bench skips the timer compare only at the boundary after an entry.
   Not a difference in behaviour.

How the bench stimulates the core: ports P1/P3 pins from the value of the instruction's first read row
in the trace; INT1 asserted one instruction before the instruction where MAME took the interrupt (`+lead=1`;
`+lead=0` or `2` makes the core take it one instruction late or early) and released after the P3 write
with bit 5 low. The INT1 assertion time is derived from the trace because MAME's latch raises it from a
scheduler callback after the write, not at the write (`L` rows precede the entry by about 1,700
instructions).

## What this does not show

- Timing of MAME's 8052 against the board is MAME's; the bench compares against MAME instruction by
  instruction and cycle counts only through the timers and the interrupt entry points.
- Timer 0 and INT1 are internal to both CPUs and agree at every boundary but the one after an interrupt
  entry; the core's cycle timing was not compared with MAME beyond that.
- 12 latch commands per set. Code that runs only on other commands is not exercised (the executed PCs
  are 1,371 of 1,879 reachable in `misncrft`, 1,307 of 1,878 in `wivernwg`). The static scan above
  covers the code that never ran, for the Timer 2 question.
- The serial port (used for MIDI by other QS1000 games), the wavetable engine and sound output.
- The upstream `jt8051` testbenches were not run (tools missing); `rtl/qs1000/jt8051` is unchanged.
