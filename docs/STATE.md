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
| finalgdr backup RAM | `rtl/vh_main.sv` `u_bk` | 8 x 32768 | 32 KB | yes (also the `.nvm`, after the EEPROM's 128 bytes) |
| 8052 internal RAM | `rtl/qs1000/vh_qs1000.sv` `vh_qs1000_mcu` `iram` | 8 x 256 | 256 | yes |
| 8052 external RAM 0x0000-0x00ff | `vh_qs1000_mcu` `xram` | 8 x 256 | 256 | yes |
| u7 (8052 program and data) | `vh_qs1000_mcu` `u_u7` | 8 x 131072 | 128 KB | no: ROM, from the `.mra` |
| Voice state | `rtl/qs1000/vh_qs1000_voice.sv` `st_mem` (with the loop start, the IMA state saved there, the fade level) | 219 x 32 | 876 | yes |
| Voice key-off and fade clock | `vh_qs1000_voice.sv` `rel_v`, `env_ctr`, `env_go` | 32 + 10 + 1 | 6 | yes |
| Voice sample lines | `vh_qs1000_voice.sv` `ln_mem`, tags `tg0_mem`/`tg1_mem`/`tag_v` | 128 x 64 | 1 KB | no: clear `tag_v` and they refetch |
| Voice line requests | `vh_qs1000_voice.sv` `pf_mem`, `pf_want` | 20 x 64 | 160 | no: clear `pf_want`; a voice that needs a line asks again |
| Voice volumes | `vh_qs1000_voice.sv` `lv_mem`, `rv_mem`, `vv_mem` | 8 x 32, three | 96 | yes |
| Voice pitch | `vh_qs1000_voice.sv` `kf_mem` (the entry's rate), `fe_mem` (the bent rate the pipeline adds) | 16 x 32, 18 x 32 | 136 | yes |
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
| finalgdr backup RAM bank | `vh_main.sv` `bk_bank` | 8 | yes | `m_finalgdr_backupram_bank` |
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

## Limenko revision

The CPU, its caches, the 93C46 and the QS1000 are the shared modules above (`rtl/lm_main.sv` instantiates
them); these are Limenko's own.

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| Work RAM | SDRAM `LM_WRAM` | 2 MB | 2 MB | yes (through port 2) |
| fg, md, bg VRAM | `rtl/video/lm_video.sv` `u_fg`, `u_md`, `u_bg` | 32 x 8192, three | 96 KB | yes |
| Sprite RAM, two banks | `lm_video.sv` `u_spr` | 32 x 2048 | 8 KB | yes |
| Palette | `lm_video.sv` `u_pal` | 32 x 2048 | 8 KB | yes |
| RAM at 0x8001e000 | `lm_video.sv` `u_ram` | 32 x 1024 | 4 KB | yes |
| Video registers 0-4 | `lm_video.sv` `vreg` | 5 x 32 | 20 | yes |
| spriteram_bit, the latched sprite count | `lm_video.sv` `spr_bit`, `spr_count` | 11 | 2 | yes |
| RAM at 0x40000000 (hrthouse's NVRAM, spotty's RAM) | `rtl/lm_main.sv` `u_x` | 32 x 1024 | 4 KB | yes (hrthouse: also the `.nvm`, after the EEPROM's 128 bytes) |
| 8052 bank 2-7 line buffer | `rtl/qs1000/vh_qs1000.sv` `xl_data`, `xl_tag`, `xl_v` | 128 + 16 | 18 | no: clear `xl_v` and it refetches |
| Scroll and enables latched at the interrupt | `rtl/video/lm_video.sv` `scr_l`, `en_l` | 3 x 32 + 4 | 13 | yes |
| Tile line slots, three layers | `lm_video.sv` `u_lbg`, `u_lmd`, `u_lfg` | 12 x 2048, three | 9 KB | no: redrawn each line (restore at the interrupt) |
| Sprite list copy | `rtl/video/lm_sprites.sv` `lst` | 32 x 2048 | 8 KB | no while no draw runs (restore between the swap and the next command) |
| Sprite frame buffer, two | DDR3 from 0x34000000 (`lm_fb.sv`) | 16 x 512 x 240, two | 480 KB | yes: the front buffer is the picture's sprites; and `front`, `shown` in `lm_sprites.sv` |
| Frame-buffer write queue, sprite line buffer | `rtl/video/lm_fb.sv` `qm`, `lbm` | 89 x 512, 64 x 256 | 7.6 KB | no: restore with the queue drained |
| Spotty's AT89C4051: registers, SFRs | `rtl/sound/lm_spotty.sv` `u_mcu` (jt8052) | | ~40 | yes: not reachable yet |
| Spotty's AT89C4051 internal RAM | `lm_spotty.sv` `u_iram` | 8 x 256 (128 used) | 256 | yes |
| Spotty's board latch, P3 copy, sound latch and pending | `lm_spotty.sv` `b_p1`, `b_p3`, `latch`, `pending` | 8, 8, 8, 1 | 4 | yes |
| Spotty's M6295 | `lm_spotty.sv` `u_oki` (jt6295) | | | yes: not reachable yet (as Vamphalf's M6295) |
| Spotty's M6295 sample cache | `lm_spotty.sv` `u_cache` | 8 granules | 64 | no: invalidate and it refetches |
