// The main board: E1 CPU, its memory system (vh_cpumem), and the I/O of the two in-scope boards.
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
	input             pause,
	input             cpu_tick,       // the CPU's 50 MHz clock as an enable: drives its timer

	input             vblank_irq,     // one clock at the start of the vertical blank
	input      [15:0] p1p2,           // active low, as MAME's P1_P2
	input      [7:0]  system,         // active low, as MAME's SYSTEM bits 7:0

	output reg        flip,
	output reg [7:0]  snd_latch,
	output reg        snd_latch_wr,
	// the YM2151 + M6295 boards: one-clock strobes with snd_wd; the chips' status for reads
	output reg        ym_wr,
	output reg        ym_a0,
	output reg        oki_wr,
	output reg [7:0]  snd_wd,
	output reg [1:0]  oki_bank,
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
	output     [21:4] dbg_miss_line,
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
reg         int2;

e1_cpu u_cpu (
	.clk(clk), .reset(rst), .cen(1'b1),
	.bus_req(bus_req), .bus_wr(bus_wr), .bus_io(bus_io), .bus_addr(bus_addr),
	.bus_be(bus_be), .bus_wdata(bus_wdata), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
	.if_req(if_req), .if_addr(if_addr), .if_ack(if_ack), .if_data(if_data),
	.irq_in({5'd0, int2, 1'b0}), .irq_ack(irq_ack), .pause(pause), .tick(cpu_tick),
	.retire(retire), .retire_pc(retire_pc), .retire_npc(retire_npc), .retire_sr(retire_sr),
	.dbg_rf_we(dbg_rf_we), .dbg_rf_wa(dbg_rf_wa), .dbg_rf_wd(dbg_rf_wd)
);

always @(posedge clk) begin
	if (rst) int2 <= 1'b0;
	else if (irq_ack[1]) int2 <= 1'b0;
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

vh_cpumem #(.ROM_BASE(SD_MAINCPU), .WRAM_BASE(SD_WRAM), .SPRHI_BASE(SD_SPRHI)) u_mem (
	.clk(clk), .prst(prst), .rst(rst),
	.bus_req(bus_req), .bus_wr(bus_wr), .bus_io(bus_io), .bus_addr(bus_addr),
	.bus_be(bus_be), .bus_wdata(bus_wdata), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
	.if_req(if_req), .if_addr(if_addr), .if_ack(if_ack), .if_data(if_data),
	.spr_we(spr_we), .spr_be(spr_be), .spr_addr(spr_addr), .spr_wd(spr_wd), .spr_rd(spr_rd),
	.pal_we(pal_we), .pal_be(pal_be), .pal_addr(pal_addr), .pal_wd(pal_wd), .pal_rd(pal_rd),
	.io_rd(io_rd), .io_wr(io_wr), .io_port(io_port), .io_wd(io_wd), .io_rdata(io_rdata),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_g(dl_g), .dl_gdata(dl_gdata), .dl_busy(dl_busy),
	.mem_addr(mem_addr), .mem_wrl(mem_wrl), .mem_wrh(mem_wrh), .mem_din(mem_din), .mem_dinx(mem_dinx), .mem_wrx(mem_wrx), .mem_dbl(mem_dbl),
	.mem_req(mem_req), .mem_ack(mem_ack), .mem_dout(mem_dout), .mem_doutb(mem_doutb),
	.st_imiss(st_imiss), .st_dmiss(st_dmiss), .dbg_fill_a(dbg_fill_a), .dbg_fill_d(dbg_fill_d),
	.dbg_miss(dbg_miss), .dbg_miss_ic(dbg_miss_ic), .dbg_miss_line(dbg_miss_line),
	.xflip_we(xflip_we)
);

// ---------------------------------------------------------------- I/O decode
// E1-16: 9-bit word address; Wivern Wings: 13-bit space, dword entries
wire [8:0]  pw = io_port[8:0];
wire [12:2] pd = io_port[12:2];
localparam [4:0] F_MC = 0, F_WW = 1, F_VH = 2, F_CM = 3, F_MK = 4, F_JB = 5, F_MD = 6, F_SU = 7, F_SO = 8, F_WA = 9;
wire f_mc = family == F_MC, f_vh = family == F_VH, f_cm = family == F_CM || family == F_MK;
wire f_jb = family == F_JB, f_md = family == F_MD, f_su = family == F_SU, f_so = family == F_SO, f_wa = family == F_WA;
wire m_flip  = f_mc && pw == 9'h040 || f_vh && pw == 9'h090 || f_cm && pw == 9'h080;
wire m_p1p2  = f_mc && pw == 9'h080 || f_vh && pw == 9'h181 || f_cm && pw == 9'h0c1 || f_jb && pw == 9'h090 ||
               f_md && pw == 9'h140 || f_su && pw == 9'h010 || f_so && pw == 9'h030 || f_wa && pw == 9'h0a0;
wire m_sys   = f_mc && pw == 9'h090 || f_vh && pw == 9'h180 || f_cm && pw == 9'h0c0 || f_jb && pw == 9'h150 ||
               f_md && pw == 9'h0a0 || f_su && pw == 9'h018 || f_so && pw == 9'h110 || f_wa && pw == 9'h0d0;
wire m_prt16 = f_mc && pw == 9'h0d0;
wire m_eew   = f_mc && pw == 9'h0f0 || f_vh && pw == 9'h182 || f_cm && pw == 9'h0c2 || f_jb && pw == 9'h0a0 ||
               f_md && pw == 9'h0f0 || f_su && pw == 9'h008 || f_so && pw == 9'h1a0 || f_wa && pw == 9'h060;
wire m_latch = f_mc && pw == 9'h100;
wire m_eer   = f_mc && pw[8:1] == 8'hb0 || f_vh && pw == 9'h070 || f_cm && pw == 9'h1f0 || f_jb && pw == 9'h0b0 ||
               f_md && pw == 9'h060 || f_su && pw == 9'h040 || f_so && pw == 9'h000 ||   // misncrft: 0x160-0x161
               f_wa && pw == 9'h1e0;
wire m_prt8  = f_mc && pw == 9'h1a0;
wire m_oki   = f_vh && pw == 9'h030 || f_cm && pw == 9'h130 || f_jb && pw == 9'h110 || f_md && pw == 9'h020 ||
               f_su && pw == 9'h020 || f_so && pw == 9'h050 || f_wa && pw == 9'h190;
wire [8:0] ym_base = f_vh ? 9'h050 : f_cm ? 9'h150 : f_jb ? 9'h1a0 : (f_md || f_su) ? 9'h030 : f_wa ? 9'h1c0 : 9'h160;
wire m_ym    = (f_vh || f_cm || f_jb || f_md || f_su || f_so || f_wa) && pw[8:1] == ym_base[8:1];
wire m_prtwa = f_wa && pw == 9'h160;
wire m_okib  = family == F_MK && pw == 9'h000;
wire flip_b7 = f_vh;                      // vamphalf: m_flip_bit 0x80
wire xflip   = f_jb || f_md || f_wa;      // jmpbreak_flipscreen_w at program 0xe0000000
wire w_strm  =  board && pd == 11'h180;   // 0x0600
wire w_flip  =  board && pd == 11'h200;   // 0x0800
wire w_p1p2  =  board && pd == 11'h280;   // 0x0a00
wire w_sys   =  board && pd == 11'h300;   // 0x0c00
wire w_latch =  board && pd == 11'h540;   // 0x1500
wire w_prt   =  board && pd == 11'h600;   // 0x1800
wire w_eew   =  board && pd == 11'h700;   // 0x1c00
wire w_eer   =  board && pd == 11'h7c0;   // 0x1f00

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

// SemiCom bit stream (prot_r<1>, data {2, 1}, init_wyvernwg)
reg        strm_which;
reg  [3:0] strm_idx;
wire [3:0] strm_next = strm_idx - 4'd1;
wire [1:0] strm_data = strm_which ? 2'd1 : 2'd2;
wire       strm_bit  = strm_next[3:1] == 3'd0 && strm_data[strm_next[0]];

always @* begin
	io_rdata = 32'd0;
	if (m_p1p2 || w_p1p2) io_rdata = {16'd0, p1p2};
	if (m_sys || w_sys)   io_rdata = {16'd0, 8'hff, system};
	if (m_prt16 || m_prt8) io_rdata = {16'd0, prot_rdata};
	if (w_prt)            io_rdata = {prot_rdata, prot_rdata};
	if (m_eer || w_eer)   io_rdata = {31'd0, ee_do};
	if (m_oki)            io_rdata = {24'd0, oki_dout};
	if (m_prtwa)          io_rdata = {16'd0, prot_wa_rdata};
	if (m_ym && pw[0])    io_rdata = {24'd0, ym_dout};      // the data port reads the status
	if (w_strm)           io_rdata = {31'd0, strm_bit};
end

always @(posedge clk) begin
	snd_latch_wr <= 1'b0;
	prot_wr2 <= 1'b0;
	ym_wr <= 1'b0;
	oki_wr <= 1'b0;
	if (rst) begin
		flip <= 1'b0;
		oki_bank <= 2'd0;
		ee_di <= 1'b0; ee_clk <= 1'b0; ee_cs <= 1'b0;
		strm_which <= 1'b0;
		strm_idx <= 4'd8;
	end else begin
		if (io_wr) begin
			if (m_flip || w_flip) flip <= flip_b7 ? io_wd[7] : io_wd[0];
			if (m_ym) begin ym_wr <= 1'b1; ym_a0 <= pw[0]; snd_wd <= io_wd[7:0]; end
			if (m_oki) begin oki_wr <= 1'b1; snd_wd <= io_wd[7:0]; end
			if (m_okib) oki_bank <= io_wd[1:0];
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
			if (w_prt) begin
				prot_wr2 <= 1'b1;
				prot_wd2 <= io_wd[15:0];
			end
		end
		if (io_rd && w_strm) strm_idx <= strm_next;
		// jmpbreak_flipscreen_w: a 16-bit handler, BIT(data, 15); a dword store writes the high word, then the low
		if (xflip && xflip_we) flip <= (bus_be[1:0] != 2'd0) ? bus_wdata[15] : bus_wdata[31];
	end
end

endmodule
