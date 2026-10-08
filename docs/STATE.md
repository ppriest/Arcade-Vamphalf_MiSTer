# Vamphalf state inventory

What a savestate or a state dump has to carry, kept current as RTL lands (the skill's
`savestates.md`). "Skip" needs a reason: a ROM table from the `.mra`, or something re-derived
every frame.

## RAMs

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| E1 local registers | `rtl/e1/e1_regram.sv` (5 MLAB copies, identical) | 32 x 64 | 256 | yes; one copy is enough, plus the pending write `l_we_r/l_wa_r/l_wd_r` |
| E1 internal RAM | `rtl/vh_cpumem.sv` `u_iram` | 64 x 512 | 4 KB | yes |
| Work RAM | SDRAM `SD_WRAM` | 2 MB | 2 MB | yes (in SDRAM: the dump reads it through port 2) |
| Sprite RAM above 64 KB | SDRAM `SD_SPRHI` | 192 KB | 192 KB | yes (only the power-on test writes it) |
| Sprite RAM | `rtl/video/vh_video.sv` `u_spr` | 32 x 16384 | 64 KB | yes |
| Palette | `vh_video.sv` `u_pal` | 32 x 16384 | 64 KB | yes |
| Sprite-list snapshot | `vh_video.sv` `vh_sdp` | 64 x 4096 | 32 KB | yes, or restore before the copy window (line 252) and let the copy rebuild it |
| EEPROM | `rtl/vh_eeprom93c46.v` `mem` | 16 x 64 | 128 | yes (also the `.nvm`) |
| 8052 internal RAM | `rtl/qs1000/vh_qs1000.sv` `vh_qs1000_mcu` `iram` | 8 x 256 | 256 | yes |
| 8052 external RAM 0x0000-0x00ff | `vh_qs1000_mcu` `xram` | 8 x 256 | 256 | yes |
| u7 (8052 program and data) | `vh_qs1000_mcu` `u_u7` | 8 x 131072 | 128 KB | no: ROM, from the `.mra` |
| Voice state | `rtl/qs1000/vh_qs1000_voice.sv` `st_mem` | 151 x 32 | 604 | yes |
| Voice sample lines | `vh_qs1000_voice.sv` `ln_mem`, tags `tg0_mem`/`tg1_mem`/`tag_v` | 128 x 64 | 1 KB | no: clear `tag_v` and they refetch |
| Voice line requests | `vh_qs1000_voice.sv` `pf_mem`, `pf_want` | 20 x 64 | 160 | no: clear `pf_want`; a voice that needs a line asks again |
| Voice volumes | `vh_qs1000_voice.sv` `lv_mem`, `rv_mem`, `vv_mem` | 8 x 32, three | 96 | yes |
| Voice event queue | `vh_qs1000_voice.sv` `q_mem` | 14 x 256 | 448 | no: restore with it drained |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| E1 global registers G[2..31] | `e1_cpu.sv` `G` | 30 x 32 | yes | `global_regs` |
| E1 PC, SR | `pc`, `sr` | 64 | yes | `global_regs[0..1]` |
| E1 trap table base | `trap_entry` | 32 | yes (derived from MCR) | `trap_entry` |
| E1 delay-slot state | `delay_slot`, `delay_pc`, `delay_slot_taken` | 34 | yes | same names |
| E1 interrupt block count | `intblock` | 2 | yes | `intblock` |
| E1 timer | `tr_val`, `tr_cnt`, `tr_period`, `tpr_pending`, `tpr_next`, `timer_pend` | ~90 | yes | `tr_*`, `timer_int_pending` |
| E1 first-instruction flag | `first_ins` | 1 | no (only after reset) | `m_instruction_length_valid` |
| E1 instruction in flight: `op`, `e1`, `e2`, `ilen`, `ilen_x`, `op_x`, `ipc`, `fpc`, state | `e1_cpu.sv` | ~120 | restore at an instruction boundary (state ST_INT) | `m_op`, `m_instruction_length` |
| E1 write queue, fetched blocks `fc_*`, `pf_*`, instruction port `if_*` | `e1_cpu.sv` | ~560 | no: drain the queue, drop the blocks and the port's request at the restore point | none |
| Vblank interrupt line | `vh_main.sv` `int2` | 1 | yes | the CPU's input line state |
| Flip | `vh_main.sv` `flip` | 1 | yes | `m_flipscreen` |
| Sound latch | `rtl/qs1000/vh_qs1000.sv` `latch`, `pending` | 9 | yes | `soundlatch` (`m_latched_value`, `m_latch_written`) |
| 8052 registers, SFRs, timers, serial port, interrupt state, microcode address | `rtl/qs1000/jt8052/` (`jt8052_regs`, `jt8052_periph`, `jt8052_ctrl` `uaddr`) | ~330 | yes, at an instruction boundary | `mcs51_cpu_device` state |
| Wavetable registers | `vh_qs1000_voice.sv` `wave` | 8 x 18 | yes | `m_wave_regs`; the volumes (RAMs above) are `m_channels[].m_regs[6..8]` |
| 24 MHz enable and 750 kHz tick phase | `vh_qs1000.sv` `cacc`, `tdiv` | 8 | yes | the stream position |
| Output decimation | `vh_qs1000_voice.sv` `dec_l/dec_r`, `dec_n` | 76 | no: one output sample | none |
| EEPROM pins and serial state | `vh_main.sv` `ee_di/ee_clk/ee_cs`; `vh_eeprom93c46.v` `st, cs_l, sk_l, locked, cmd, nbits, shreg, addr, op, busy` | ~80 | yes | `eeprom_serial_base_device` state |
| Mission Craft / Wivern Wings protection | `rtl/vh_prot.sv` `retval, idx, armed, ok16, ok8, okw` | 34 | yes (the seed itself is not stored: the match flags are its state) | `m_seed, m_retval, m_idx, m_is_armed` |
| SemiCom bit stream | `vh_main.sv` `strm_which, strm_idx` | 5 | yes | `m_semicom_prot_which, m_semicom_prot_idx` |
| Memory unit FSM, write buffer, instruction-port lookup | `vh_cpumem.sv` `st`, `wq_*`, `m_who`, `i_*` | ~400 | no: restore with the CPU between accesses and the buffer drained | none |

## Chip state

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| | | | | |

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| E1 operand registers `lS_r`, `gS_r`, ... and the multiplier pipeline | re-read from the register file at the next operand-read state |
| I-cache and D-cache contents | write-through: SDRAM holds every value; the caches are swept (`S_INIT`) after a restore |
| Line buffers, sprite FIFO, row FIFO | rebuilt every line |

## Frame alignment

Restore point (normally `frame_start`), and anything whose phase must be saved with it: sprite or
tile double-buffer selection, snapshot ownership bits.
