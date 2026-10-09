// The main board: E1 CPU, its memory system (vh_cpumem), and the I/O maps of every family.
//
// I/O space (the port is the CPU's I/O address >> 13, e132xs.cpp m_read_io / m_write_io; MAME's I/O maps
// count in that unit: 16-bit words on the E1-16 (address shift -1), so 0x180 and 0x181 are two ports):
//   Mission Craft (board 0, misncrft_io, 16-bit: a word read gives bits 15:0, zero-extended)
//     0x040 W flip (bit 0)          0x080 R P1_P2          0x090 R SYSTEM
//     0x0d0 RW protection, 16-byte seeds                    0x1a0 RW protection, 8-byte seeds
//     0x0f0 W EEPROM (bit 0 DI, 1 CLK, 2 CS)                0x160 R EEPROM DO (bit 0)
//     0x100 W sound latch (bits 7:0)
//   Wivern Wings (board 1, wyvernwg_io, 32-bit)
//     0x0600 R SemiCom bit stream (prot_r<1>)  W select     0x0800 W flip (bit 0)
//     0x0a00 R P1_P2                0x0c00 R SYSTEM          0x1500 W sound latch (bits 7:0)
//     0x1800 RW protection, 16-word seeds                    0x1c00 W EEPROM     0x1f00 R EEPROM DO
//   Unmapped ports read 0.
//   The YM2151 + M6295 boards (family 2 on, all E1-16), per their map in vamphalf.cpp:
//     family 2 vamphalf_io:  0x030 OKI, 0x050/0x051 YM, 0x070 R EEPROM, 0x090 W flip (bit 7),
//                            0x180 R SYSTEM, 0x181 R P1_P2, 0x182 W EEPROM
//     family 3 coolmini_io:  0x080 W flip, 0x0c0 R SYSTEM, 0x0c1 R P1_P2, 0x0c2 W EEPROM, 0x130 OKI,
//                            0x150/0x151 YM, 0x1f0 R EEPROM
//     family 4 mrkicker_io:  coolmini_io, and 0x000 W OKI bank (bits 1:0)
//     family 5 jmpbreak_io:  0x090 R P1_P2, 0x0a0 W EEPROM, 0x0b0 R EEPROM, 0x110 OKI, 0x150 R SYSTEM,
//                            0x1a0/0x1a1 YM; flip at program 0xe0000000, bit 15
//     family 6 mrdig_io:     0x020 OKI, 0x030/0x031 YM, 0x060 R EEPROM, 0x0a0 R SYSTEM, 0x0f0 W EEPROM,
//                            0x140 R P1_P2; flip at program 0xe0000000, bit 15
//     family 7 suplup_io:    0x008 W EEPROM, 0x010 R P1_P2, 0x018 R SYSTEM, 0x020 OKI, 0x030/0x031 YM,
//                            0x040 R EEPROM; no flip
//     family 8 solitaire_io: 0x000 R EEPROM, 0x030 R P1_P2, 0x050 OKI, 0x110 R SYSTEM, 0x160/0x161 YM,
//                            0x1a0 W EEPROM; no flip
//     family 9 worldadv_io:  0x060 W EEPROM, 0x0a0 R P1_P2, 0x0d0 R SYSTEM, 0x160 RW protection (vh_prot_wa),
//                            0x190 OKI, 0x1c0/0x1c1 YM, 0x1e0 R EEPROM; flip at program 0xe0000000, bit 15
//   The OKI and YM entries are umask16(0x00ff): data in bits 7:0. The E1-16 maps decode all 9 bits of the
//   word address; Wivern Wings' 32-bit map ignores the two below its dwords.
//
// The vertical blank interrupt is INT2, held until the CPU takes it: MAME's irq1_line_hold asserts input
// line 1, which the E1 numbers INPUT_INT2 (e132xs.h; ISR bit 1, inhibited by FCR bit 29).

module vh_main (
	input             clk,
	input             prst,           // power-up reset of the memory side (not the core reset)
	input             rst,
	input             board,          // 0 E1-16 board, 1 E1-32 board (Wivern Wings)
	input      [4:0]  family,         // the I/O map: 0 misncrft_io, 1 wyvernwg_io, 2.. the YM2151 + M6295 maps
	input             prg2,           // a 2 MB program, from 0xffe00000 (yorijori)
	input             pause,
	input             cpu_tick,       // the CPU's 50 MHz clock as an enable: drives its timer

	input             vblank_irq,     // one clock at the start of the vertical blank
	input      [15:0] p1p2,           // active low, as MAME's P1_P2
	input      [7:0]  system,         // active low, as MAME's SYSTEM bits 7:0
	input      [6:0]  xbtn,           // active low: solitaire's buttons 5-11

	output reg        flip,
	output reg [7:0]  snd_latch,
	output reg        snd_latch_wr,
	// the YM2151 + M6295 boards: one-clock strobes with snd_wd; the chips' status for reads
	output reg        ym_wr,
	output reg        ym_a0,
	output reg        oki_wr,
	output reg [7:0]  snd_wd,
	output reg [2:0]  oki_bank,
	input      [7:0]  ym_dout,
	input      [7:0]  oki_dout,

	// video RAMs
	output            spr_we,
	output     [3:0]  spr_be,
	output     [13:0] spr_addr,
	output     [31:0] spr_wd,
	input      [31:0] spr_rd,
	output            pal_we,
	output     [3:0]  pal_be,
	output     [13:0] pal_addr,
	output     [31:0] pal_wd,
	input      [31:0] pal_rd,

	// EEPROM image: load during the download, read back for the NVRAM save
	input             ee_blank,
	input             ee_load_we,
	input      [5:0]  ee_load_addr,
	input      [15:0] ee_load_data,
	input      [5:0]  ee_rd_addr,
	output     [15:0] ee_rd_data,
	output            ee_written,

	// finalgdr's backup RAM: written by the .nvm load (the CPU is in reset), read back for the save
	input             bk_load,
	input             bk_load_we,
	input      [14:0] bk_load_addr,
	input      [7:0]  bk_load_data,
	input      [14:0] bk_rd_addr,
	output     [7:0]  bk_rd_data,
	output            bk_written,

	// ROM download writes, and SDRAM port 2
	input             dl_req,
	input      [26:0] dl_addr,
	input      [15:0] dl_data,
	input             dl_we16,
	input             dl_g,
	input      [63:0] dl_gdata,
	output            dl_busy,
	output     [26:1] mem_addr,
	output            mem_wrl,
	output            mem_wrh,
	output     [15:0] mem_din,
	output     [47:0] mem_dinx,
	output      [5:0] mem_wrx,
	output            mem_dbl,
	output            mem_req,
	input             mem_ack,
	input      [63:0] mem_dout,
	input      [63:0] mem_doutb,

	// for the benches
	output            retire,
	output     [31:0] retire_pc,
	output     [31:0] retire_npc,      // the PC after it (e1_cpu)
	output     [31:0] retire_sr,
	output     [31:0] st_imiss,
	output     [31:0] st_dmiss,
	output     [26:1] dbg_fill_a,
	output     [63:0] dbg_fill_d,
	output            dbg_miss,
	output            dbg_miss_ic,
	output     [22:4] dbg_miss_line,
	output            dbg_rf_we,
	output     [5:0]  dbg_rf_wa,
	output     [31:0] dbg_rf_wd,

	// architectural trace (rtl/debug/vh_trace.sv): the bench prints trace_rec, the probe build reads
	// the buffer; with the outputs unconnected (release build) it is removed
	input      [23:0] trace_start,
	input      [11:0] trace_idx,
	output            trace_valid,
	output    [187:0] trace_rec,
	output    [187:0] trace_q,
	output     [12:0] trace_count
);

`include "vh_sdram_map.svh"

// ---------------------------------------------------------------- CPU
wire        bus_req, bus_wr, bus_io, bus_ack;
wire        if_req, if_ack;
wire [31:3] if_addr;
wire [63:0] if_data;
wire [31:0] bus_addr, bus_wdata, bus_rdata;
wire [3:0]  bus_be;
wire [6:0]  irq_ack;
reg         int2;                  // vblank: INT2 (irq1_line_hold), on yorijori INT3 (irq2_line_hold)
wire        vbl3 = family == 5'd11;

e1_cpu u_cpu (
	.clk(clk), .reset(rst), .cen(1'b1),
	.bus_req(bus_req), .bus_wr(bus_wr), .bus_io(bus_io), .bus_addr(bus_addr),
	.bus_be(bus_be), .bus_wdata(bus_wdata), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
	.if_req(if_req), .if_addr(if_addr), .if_ack(if_ack), .if_data(if_data),
	.irq_in({4'd0, vbl3 && int2, !vbl3 && int2, 1'b0}), .irq_ack(irq_ack), .pause(pause), .tick(cpu_tick),
	.retire(retire), .retire_pc(retire_pc), .retire_npc(retire_npc), .retire_sr(retire_sr),
	.dbg_rf_we(dbg_rf_we), .dbg_rf_wa(dbg_rf_wa), .dbg_rf_wd(dbg_rf_wd)
);

always @(posedge clk) begin
	if (rst) int2 <= 1'b0;
	else if (irq_ack[1] || irq_ack[2]) int2 <= 1'b0;
	else if (vblank_irq) int2 <= 1'b1;
end

vh_trace u_trace (
	.clk(clk), .rst(rst), .start(trace_start),
	.retire(retire), .npc(retire_npc), .sr(retire_sr),
	.rf_we(dbg_rf_we), .rf_wa(dbg_rf_wa), .rf_wd(dbg_rf_wd),
	.bus_req(bus_req), .bus_ack(bus_ack), .bus_wr(bus_wr), .bus_io(bus_io),
	.bus_be(bus_be), .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
	.rec_valid(trace_valid), .rec(trace_rec), .rd_idx(trace_idx), .rd_q(trace_q), .count(trace_count)
);

// ---------------------------------------------------------------- memory
wire        io_rd, io_wr, xflip_we;
wire [18:0] io_port;
wire [31:0] io_wd;
reg  [31:0] io_rdata;
wire        g_bram;                       // finalgdr's backup RAM window (decoded below)

vh_cpumem #(.ROM_BASE(SD_MAINCPU), .WRAM_BASE(SD_WRAM), .SPRHI_BASE(SD_SPRHI), .PRGLO_BASE(SD_PRGLO)) u_mem (
	.clk(clk), .prst(prst), .rst(rst), .prg2(prg2),
	.bus_req(bus_req), .bus_wr(bus_wr), .bus_io(bus_io), .bus_addr(bus_addr),
	.bus_be(bus_be), .bus_wdata(bus_wdata), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
	.if_req(if_req), .if_addr(if_addr), .if_ack(if_ack), .if_data(if_data),
	.spr_we(spr_we), .spr_be(spr_be), .spr_addr(spr_addr), .spr_wd(spr_wd), .spr_rd(spr_rd),
	.pal_we(pal_we), .pal_be(pal_be), .pal_addr(pal_addr), .pal_wd(pal_wd), .pal_rd(pal_rd),
	.io_rd(io_rd), .io_wr(io_wr), .io_port(io_port), .io_wd(io_wd), .io_rdata(io_rdata), .io_late(g_bram),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_g(dl_g), .dl_gdata(dl_gdata), .dl_busy(dl_busy),
	.mem_addr(mem_addr), .mem_wrl(mem_wrl), .mem_wrh(mem_wrh), .mem_din(mem_din), .mem_dinx(mem_dinx), .mem_wrx(mem_wrx), .mem_dbl(mem_dbl),
	.mem_req(mem_req), .mem_ack(mem_ack), .mem_dout(mem_dout), .mem_doutb(mem_doutb),
	.st_imiss(st_imiss), .st_dmiss(st_dmiss), .dbg_fill_a(dbg_fill_a), .dbg_fill_d(dbg_fill_d),
	.dbg_miss(dbg_miss), .dbg_miss_ic(dbg_miss_ic), .dbg_miss_line(dbg_miss_line),
	.xflip_we(xflip_we)
);

// ---------------------------------------------------------------- I/O decode
// E1-16: 9-bit word address; E1-32: 13-bit space, dword entries (MAME's map address is io_port)
wire [8:0]  pw = io_port[8:0];
wire [12:2] pd = io_port[12:2];
wire [12:0] pk = io_port[12:0];
localparam [4:0] F_MC = 0, F_WW = 1, F_VH = 2, F_CM = 3, F_MK = 4, F_JB = 5, F_MD = 6, F_SU = 7, F_SO = 8, F_WA = 9,
                 F_KA = 10, F_YJ = 11, F_BG = 12, F_FG = 13;
wire f_ww = family == F_WW, f_ka = family == F_KA, f_yj = family == F_YJ, f_bg = family == F_BG, f_fg = family == F_FG;
wire f_mc = family == F_MC, f_vh = family == F_VH, f_cm = family == F_CM || family == F_MK;
wire f_jb = family == F_JB, f_md = family == F_MD, f_su = family == F_SU, f_so = family == F_SO, f_wa = family == F_WA;
wire m_flip  = f_mc && pw == 9'h040 || f_vh && pw == 9'h090 || f_cm && pw == 9'h080 || f_bg && pw == 9'h0c0;
wire m_p1p2  = f_mc && pw == 9'h080 || f_vh && pw == 9'h181 || f_cm && pw == 9'h0c1 || f_jb && pw == 9'h090 ||
               f_md && pw == 9'h140 || f_su && pw == 9'h010 || f_so && pw == 9'h030 || f_wa && pw == 9'h0a0;
wire b_p1p2  = f_bg && pw == 9'h101;
wire m_sys   = f_mc && pw == 9'h090 || f_vh && pw == 9'h180 || f_cm && pw == 9'h0c0 || f_jb && pw == 9'h150 ||
               f_md && pw == 9'h0a0 || f_su && pw == 9'h018 || f_so && pw == 9'h110 || f_wa && pw == 9'h0d0 ||
               f_bg && pw == 9'h100;
wire m_prt16 = f_mc && pw == 9'h0d0;
wire m_eew   = f_mc && pw == 9'h0f0 || f_vh && pw == 9'h182 || f_cm && pw == 9'h0c2 || f_jb && pw == 9'h0a0 ||
               f_md && pw == 9'h0f0 || f_su && pw == 9'h008 || f_so && pw == 9'h1a0 || f_wa && pw == 9'h060 ||
               f_bg && pw == 9'h102;
wire m_latch = f_mc && pw == 9'h100;
wire m_eer   = f_mc && pw[8:1] == 8'hb0 || f_vh && pw == 9'h070 || f_cm && pw == 9'h1f0 || f_jb && pw == 9'h0b0 ||   // misncrft: 0x160-0x161
               f_md && pw == 9'h060 || f_su && pw == 9'h040 || f_so && pw == 9'h000 ||
               f_wa && pw == 9'h1e0 || f_bg && pw == 9'h030;
wire m_prt8  = f_mc && pw == 9'h1a0;
wire m_oki   = f_vh && pw == 9'h030 || f_cm && pw == 9'h130 || f_jb && pw == 9'h110 || f_md && pw == 9'h020 ||
               f_su && pw == 9'h020 || f_so && pw == 9'h050 || f_wa && pw == 9'h190 || f_bg && pw == 9'h1c0;
wire [8:0] ym_base = f_vh ? 9'h050 : f_cm ? 9'h150 : f_jb ? 9'h1a0 : (f_md || f_su) ? 9'h030 : f_wa ? 9'h1c0 :
                     f_bg ? 9'h1d0 : 9'h160;
wire m_ym    = (f_vh || f_cm || f_jb || f_md || f_su || f_so || f_wa || f_bg) && pw[8:1] == ym_base[8:1];
wire m_prtwa = f_wa && pw == 9'h160;
wire m_okib  = family == F_MK && pw == 9'h000;
wire b_okib  = f_bg && pw == 9'h180;     // boonggab_oki_bank_w: 8 banks
wire flip_b7 = f_vh;                      // vamphalf: m_flip_bit 0x80
wire xflip   = f_jb || f_md || f_wa;      // jmpbreak_flipscreen_w at program 0xe0000000
wire w_strm  =  f_ww && pd == 11'h180;   // 0x0600
wire w_flip  =  f_ww && pd == 11'h200;   // 0x0800
wire w_p1p2  =  f_ww && pd == 11'h280;   // 0x0a00
wire w_sys   =  f_ww && pd == 11'h300;   // 0x0c00
wire w_latch =  f_ww && pd == 11'h540;   // 0x1500
wire w_prt   =  f_ww && pd == 11'h600;   // 0x1800
wire w_eew   =  f_ww && pd == 11'h700;   // 0x1c00
wire w_eer   =  f_ww && pd == 11'h7c0;   // 0x1f00
// mrkickera_io (vamphalf.cpp:585-599) and finalgdr_io (:567-583), the same handlers at other ports; the sound
// chips and the inputs are on bits 15:8 and 31:16
wire k_eer   =  f_ka && pk == 13'h0900 || f_fg && pk == 13'h1100;
wire k_eew   =  f_ka && pk == 13'h1000 || f_fg && pk == 13'h1800;  // finalgdr_eeprom_w: DI 14, CLK 13, CS 12; reads 0
wire k_strw  =  f_ka && pk == 13'h1010 || f_fg && pk == 13'h1810;  // finalgdr_prot_w
wire k_okib  =  f_ka && pk == 13'h1028 || f_fg && pk == 13'h1828;  // finalgdr_oki_bank_w: bits 9:8
wire k_strr  =  f_ka && pk == 13'h1900 || f_fg && pk == 13'h0900;  // prot_r<0x8000>
wire k_ym    =  f_ka && pk[12:1] == 12'he00 || f_fg && pk[12:1] == 12'h600;   // address, then data
wire k_oki   =  f_ka && pk == 13'h1d00 || f_fg && pk == 13'h0d00;
wire k_p1p2  =  f_ka && pk == 13'h1e00 || f_fg && pk == 13'h0e00;
wire k_sys   =  f_ka && pk == 13'h1f00 || f_fg && pk == 13'h0f00;
// finalgdr's backup RAM (finalgdr_backupram_r/w): 256 banks of 128 bytes, the byte on bits 31:24; the bank
// register is bits 31:24 at 0x0a00, 1 from init_finalgdr
wire g_bank  =  f_fg && pk == 13'h0a00;
assign g_bram = f_fg && pk[12:7] == 6'h16;   // 0x0b00-0x0b7f
// yorijori_io (vamphalf.cpp:683-693): the QS1000's latch on bits 15:8
wire y_strr  =  f_yj && pk == 13'h0900;  // prot_r<0x8000>
wire y_p1p2  =  f_yj && pk == 13'h0d00;
wire y_latch =  f_yj && pk == 13'h0e00;
wire y_sys   =  f_yj && pk == 13'h0f00;
wire y_eer   =  f_yj && pk == 13'h1100;
wire y_eew   =  f_yj && pk == 13'h1800;  // yorijori_eeprom_w: DI bit 12, CLK 13, CS 14; reads 0 (nopr)
wire y_strw  =  f_yj && pk == 13'h1810;  // finalgdr_prot_w
// finalgdr inputs: per player U D L R, buttons 1-3, Start; SYSTEM COIN1, COIN2, 4 unused, SERVICE1, service mode
// (yorijori's: per player U D L R, buttons 1-4, as the common port's; SYSTEM as finalgdr's)
wire [15:0] ka_p1p2 = {system[7], p1p2[14:8], system[6], p1p2[6:0]};
wire [7:0]  ka_sys  = {system[4], system[1], 4'hf, system[2], system[0]};
// solitaire (vamphalf.cpp:1102-1131): P1_P2 bits 6:0 columns 1-7 (buttons 1-4, then xbtn 2:0), bits 11:8 Turn Up
// Card, Select Turned Up Card, Register, Gift (xbtn 6:3); SYSTEM is the common port's
wire [15:0] so_p1p2 = {4'hf, xbtn[6:3], 1'b1, xbtn[2:0], p1p2[7:4]};
// boonggab (vamphalf.cpp:1032-1060): P1_P2 bit 0 START1, bits 2/3 left/right, bits 13:11 the photo sensors'
// strength code (boonggab_photo_sensors_r's 7 none .. 0 strongest, read inverted as the field is active low:
// MAME reads 0xc7ff idle, 0xcfff with the weakest; buttons 1-4 here give MAME's 1st, 3rd, 5th and 7th
// strengths, HACKS.md), bits 10:8 sensors 1-3 idle; SYSTEM bits 7:6 unused
wire [2:0]  bg_hit  = !p1p2[7] ? 3'd7 : !p1p2[6] ? 3'd5 : !p1p2[5] ? 3'd3 : !p1p2[4] ? 3'd1 : 3'd0;
wire [15:0] bg_p1p2 = {2'b11, bg_hit, 3'b111, 4'hf, p1p2[3], p1p2[2], 1'b1, system[6]};

// EEPROM
reg  ee_di, ee_clk, ee_cs;
wire ee_do;
// vamphalf.cpp common(): write and erase take 1 us (MAME_KLUDGES.md); the -all commands keep MAME's 8 ms
vh_eeprom93c46 #(.CLK_KHZ(56000), .WRITE_US(1), .ERASE_US(1)) u_ee (
	.rst(rst), .blank(ee_blank), .clk(clk), .cs(ee_cs), .sk(ee_clk), .di(ee_di), .dout(ee_do), .dbg(),
	.load_we(ee_load_we), .load_addr(ee_load_addr), .load_data(ee_load_data),
	.rd_addr(ee_rd_addr), .rd_data(ee_rd_data), .written(ee_written)
);

// protection. Wivern Wings' 0x1800 is a 16-bit handler on the 32-bit bus: MAME calls it once per
// half, in ascending address order, so a dword write is the high half's value, then the low half's
// (emumem_heu.cpp sorts the subunits by offset). Unverified against a trace: docs/HACKS.md.
wire [15:0] prot_rdata;
reg         prot_wr2;                    // the low half of a Wivern Wings dword, one clock later
reg  [15:0] prot_wd2;
wire        prot_wr = io_wr && (m_prt16 || m_prt8 || w_prt) || prot_wr2;
wire [15:0] prot_wd = prot_wr2 ? prot_wd2 : (board ? io_wd[31:16] : io_wd[15:0]);
wire [15:0] prot_wa_rdata;
vh_prot_wa u_prot_wa (.clk(clk), .rst(rst), .wr(io_wr && m_prtwa), .wd(io_wd[15:0]), .rd(io_rd && m_prtwa),
	.rdata(prot_wa_rdata));
vh_prot u_prot (.clk(clk), .rst(rst), .board(board), .wr(prot_wr), .tab16(m_prt16), .wd(prot_wd),
	.rd(io_rd && (m_prt16 || m_prt8)), .rdata(prot_rdata));

// SemiCom bit stream: prot_r<1>, data {2, 1} (init_wyvernwg); mrkickera prot_r<0x8000>, data {2, 3}
// (init_mrkickera, MAME_KLUDGES.md)
reg        strm_which;
reg  [3:0] strm_idx;
wire [3:0] strm_next = strm_idx - 4'd1;
wire [1:0] strm_data = strm_which ? ((f_ka || f_fg || f_yj) ? 2'd3 : 2'd1) : 2'd2;

reg  [7:0] bk_bank;
wire [7:0] bk_q;
vh_dpram #(.AW(15), .DW(8), .NBE(1)) u_bk (
	.clk(clk), .a_ce(1'b1),
	.a_we(bk_load ? bk_load_we : io_wr && g_bram),
	.a_addr(bk_load ? bk_load_addr : {bk_bank, pk[6:0]}),
	.a_wd(bk_load ? bk_load_data : io_wd[31:24]),
	.a_rd(bk_q), .b_addr(bk_rd_addr), .b_rd(bk_rd_data)
);
assign bk_written = io_wr && g_bram;
wire       strm_bit  = strm_next[3:1] == 3'd0 && strm_data[strm_next[0]];

always @* begin
	io_rdata = 32'd0;
	if (m_p1p2 || w_p1p2) io_rdata = {16'd0, f_so ? so_p1p2 : p1p2};
	if (m_sys || w_sys)   io_rdata = {16'd0, 8'hff, f_bg ? {2'b11, system[5:0]} : system};
	if (b_p1p2)           io_rdata = {16'd0, bg_p1p2};
	if (m_prt16 || m_prt8) io_rdata = {16'd0, prot_rdata};
	if (w_prt)            io_rdata = {prot_rdata, prot_rdata};
	if (m_eer || w_eer)   io_rdata = {31'd0, ee_do};
	if (m_oki)            io_rdata = {24'd0, oki_dout};
	if (m_prtwa)          io_rdata = {16'd0, prot_wa_rdata};
	if (m_ym && pw[0])    io_rdata = {24'd0, ym_dout};      // the data port reads the status
	if (w_strm)           io_rdata = {31'd0, strm_bit};
	if (k_p1p2)           io_rdata = {ka_p1p2, 16'd0};
	if (k_sys)            io_rdata = {8'd0, ka_sys, 16'd0};
	if (k_eer)            io_rdata = {31'd0, ee_do};
	if (k_strr)           io_rdata = {16'd0, strm_bit, 15'd0};
	if (k_ym && pk[0])    io_rdata = {16'd0, ym_dout, 8'd0};
	if (k_oki)            io_rdata = {16'd0, oki_dout, 8'd0};
	if (y_p1p2)           io_rdata = {p1p2, 16'd0};
	if (y_sys)            io_rdata = {8'd0, ka_sys, 16'd0};
	if (y_eer)            io_rdata = {31'd0, ee_do};
	if (y_strr)           io_rdata = {16'd0, strm_bit, 15'd0};
	if (g_bram)           io_rdata = {bk_q, 24'd0};   // a clock after io_rd (io_late)
end

always @(posedge clk) begin
	snd_latch_wr <= 1'b0;
	prot_wr2 <= 1'b0;
	ym_wr <= 1'b0;
	oki_wr <= 1'b0;
	if (rst) begin
		flip <= 1'b0;
		oki_bank <= 3'd0;
		ee_di <= 1'b0; ee_clk <= 1'b0; ee_cs <= 1'b0;
		strm_which <= 1'b0;
		strm_idx <= 4'd8;
		bk_bank <= 8'd1;
	end else begin
		if (io_wr) begin
			if (m_flip || w_flip) flip <= flip_b7 ? io_wd[7] : io_wd[0];
			if (m_ym) begin ym_wr <= 1'b1; ym_a0 <= pw[0]; snd_wd <= io_wd[7:0]; end
			if (m_oki) begin oki_wr <= 1'b1; snd_wd <= io_wd[7:0]; end
			if (m_okib) oki_bank <= {1'b0, io_wd[1:0]};
			if (b_okib) oki_bank <= io_wd[2:0];
			if (m_eew || w_eew) begin
				ee_di <= io_wd[0]; ee_clk <= io_wd[1]; ee_cs <= io_wd[2];
			end
			if (m_latch || w_latch) begin
				snd_latch <= io_wd[7:0];
				snd_latch_wr <= 1'b1;
			end
			if (w_strm) begin
				strm_which <= io_wd[0];
				strm_idx <= 4'd8;
			end
			if (y_strw) begin
				strm_which <= !(io_wd == 32'h41c6 || io_wd == 32'h446b);
				strm_idx <= 4'd8;
			end
			if (y_eew) begin
				ee_di <= io_wd[12]; ee_clk <= io_wd[13]; ee_cs <= io_wd[14];
			end
			if (y_latch) begin
				snd_latch <= io_wd[15:8];
				snd_latch_wr <= 1'b1;
			end
			if (k_strw) begin
				strm_which <= !(io_wd == 32'h41c6 || io_wd == 32'h446b);
				strm_idx <= 4'd8;
			end
			if (k_eew) begin
				ee_di <= io_wd[14]; ee_clk <= io_wd[13]; ee_cs <= io_wd[12];
			end
			if (k_ym) begin ym_wr <= 1'b1; ym_a0 <= pk[0]; snd_wd <= io_wd[15:8]; end
			if (k_oki) begin oki_wr <= 1'b1; snd_wd <= io_wd[15:8]; end
			if (k_okib) oki_bank <= {1'b0, io_wd[9:8]};
			if (g_bank) bk_bank <= io_wd[31:24];
			if (w_prt) begin
				prot_wr2 <= 1'b1;
				prot_wd2 <= io_wd[15:0];
			end
		end
		if (io_rd && (w_strm || k_strr || y_strr)) strm_idx <= strm_next;
		// jmpbreak_flipscreen_w: a 16-bit handler, BIT(data, 15); a dword store writes the high word, then the low
		if (xflip && xflip_we) flip <= (bus_be[1:0] != 2'd0) ? bus_wdata[15] : bus_wdata[31];
	end
end

endmodule
