// The QS1000 sound board as vamphalf.cpp and qs1000.cpp have it: an 8052 on the 24 MHz oscillator, its
// program and data in u7, a sound latch from the main CPU, and the wavetable engine reading the
// sample ROM from SDRAM.
//
//   8052 program  0x0000-0x7fff  u7 (MAME maps only the first 32 KB; above reads 0xff)
//   8052 data     0x0000-0x00ff  RAM
//                 0x0100-0xffff  u7[(bank * 0x7f00 + addr) mod 128 KB], bank = P3 bits 2:0 (MAME
//                                reloads u7 four times in its 512 KB region, so the wrap is exact)
//                 0x0200-0x0211  writes also go to the wavetable engine
//   P1 in         the latch      INT1 is the latch's pending flag: set by the main CPU's write,
//                                cleared by a write to P3 with bit 5 low (qs1000_p3_w)
//
// 24 MHz is 3 enables in every 7 clocks of 56 MHz (never two in a row, which jt8052 requires); the
// engine's 750 kHz tick is every 32nd enable, as MAME's 24 MHz / 32.
module vh_qs1000 (
	input               clk,
	input               rst,

	input               dl_we,           // u7 download, while rst is held
	input       [16:0]  dl_addr,
	input       [7:0]   dl_data,

	input               latch_wr,
	input       [7:0]   latch_d,
	input               bal_pcb,         // mix balance: the PCB recording's, or MAME's (vh_qs1000_voice)

	// SDRAM port 1: one 16-byte line of the sample region per request (double read)
	output reg  [26:1]  sd_addr,
	output reg          sd_req,
	input               sd_ack,
	input       [63:0]  sd_dout,
	input       [63:0]  sd_doutb,

	output signed [15:0] out_l,
	output signed [15:0] out_r,

	output      [15:0]  dbg_drops,
	output      [15:0]  dbg_stalls
);

`include "vh_sdram_map.svh"

// 24 MHz enable and the 750 kHz tick
reg [2:0] cacc;
reg       cen;
reg [4:0] tdiv;
reg       tick;
always @(posedge clk) begin
	tick <= 1'b0;
	if (rst) begin
		cacc <= 3'd0; cen <= 1'b0; tdiv <= 5'd0;
	end else begin
		if (cacc >= 3'd4) begin cacc <= cacc - 3'd4; cen <= 1'b1; end
		else begin cacc <= cacc + 3'd3; cen <= 1'b0; end
		if (cen) begin
			tdiv <= tdiv + 5'd1;
			if (tdiv == 5'd31) tick <= 1'b1;
		end
	end
end

// sound latch
reg [7:0] latch;
reg       pending;
wire      p3_we;
wire [7:0] p3_latch;
always @(posedge clk) begin
	if (rst) begin
		latch <= 8'd0; pending <= 1'b0;
	end else begin
		if (cen && p3_we && !p3_latch[5]) pending <= 1'b0;   // one enable after the write
		if (latch_wr) begin latch <= latch_d; pending <= 1'b1; end
	end
end

wire        x_acc, x_wr;
wire [15:0] x_addr;
wire [7:0]  x_dout;
vh_qs1000_mcu u_mcu (
	.clk(clk), .rst(rst), .cen(cen),
	.dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data),
	.p1_i(latch), .int1n(~pending),
	.p1_o(), .p2_o(), .p3_o(), .p3_latch(p3_latch), .p3_we(p3_we),
	.x_acc(x_acc), .x_wr(x_wr), .x_addr(x_addr), .x_dout(x_dout), .x_din()
);

wire wave_wr = cen && x_acc && x_wr && x_addr[15:5] == 11'h010 && x_addr[4:0] <= 5'h11;

wire         rom_req;
wire [19:0]  rom_line;
reg          rom_ack;
reg  [127:0] rom_data;
vh_qs1000_voice u_voice (
	.clk(clk), .rst(rst),
	.wr(wave_wr), .wr_off(x_addr[4:0]), .wr_data(x_dout),
	.tick(tick), .bal_pcb(bal_pcb),
	.rom_req(rom_req), .rom_line(rom_line), .rom_ack(rom_ack), .rom_data(rom_data),
	.mix_valid(), .mix_l(), .mix_r(),
	.out_l(out_l), .out_r(out_r),
	.dbg_drops(dbg_drops), .dbg_stalls(dbg_stalls)
);

// sample ROM lines from SDRAM. The region holds MAME's first 4 MB; MAME's region is 16 MB with
// nothing above 0x280000, so lines past 4 MB read as zero without a request.
function [63:0] sw64(input [63:0] g);
	sw64 = {g[7:0], g[15:8], g[23:16], g[31:24], g[39:32], g[47:40], g[55:48], g[63:56]};
endfunction

reg sd_busy;
always @(posedge clk) begin
	rom_ack <= 1'b0;
	if (rst) begin
		sd_busy <= 1'b0;
		sd_req <= sd_ack;
	end else if (!sd_busy) begin
		if (rom_req && !rom_ack) begin
			if (rom_line[19:18] != 2'd0) begin
				rom_data <= 128'd0;
				rom_ack <= 1'b1;
			end else begin
				sd_addr <= SD_SAMPLES[26:1] + {rom_line[17:0], 3'b000};
				sd_req <= ~sd_req;
				sd_busy <= 1'b1;
			end
		end
	end else if (sd_req == sd_ack) begin
		rom_data <= {sw64(sd_dout), sw64(sd_doutb)};
		rom_ack <= 1'b1;
		sd_busy <= 1'b0;
	end
end

endmodule


// The 8052 and its memories. u7 is one 128 KB dual-port block RAM: port A serves program reads and
// the download, port B the banked data window. Reads are registered: program and internal RAM on the
// enable (the data the core samples at the next enable), the data window every clock, which is
// current at the next enable because enables are never adjacent and the address only changes on one.
module vh_qs1000_mcu (
	input               clk,
	input               rst,
	input               cen,

	input               dl_we,
	input       [16:0]  dl_addr,
	input       [7:0]   dl_data,

	input       [7:0]   p1_i,
	input               int1n,
	output      [7:0]   p1_o,
	output      [7:0]   p2_o,
	output      [7:0]   p3_o,
	output      [7:0]   p3_latch,
	output              p3_we,

	output              x_acc,
	output              x_wr,
	output      [15:0]  x_addr,
	output      [7:0]   x_dout,
	output      [7:0]   x_din
);

wire [15:0] rom_addr;
wire [7:0]  ram_addr, ram_dout;
wire        ram_we;
wire [7:0]  ram_din;
reg         rom_hi;

// u7: the bank offset bank * 0x7f00 is bank * 0x8000 - bank * 0x100
wire [17:0] xb = {p3_latch[2:0], 15'd0} - {7'd0, p3_latch[2:0], 8'd0} + {2'd0, x_addr};
wire [7:0]  u7_qa, u7_qb;
vh_dpram #(.AW(17), .DW(8), .NBE(1)) u_u7 (
	.clk(clk), .a_ce(cen | dl_we), .a_we(dl_we), .a_addr(dl_we ? dl_addr : {2'd0, rom_addr[14:0]}),
	.a_wd(dl_data), .a_rd(u7_qa),
	.b_addr(xb[16:0]), .b_rd(u7_qb)
);

// internal RAM: read and written on the enable (Vamphalf.sdc gives the 8052's paths into it two clocks)
vh_dpram #(.AW(8), .DW(8), .NBE(1)) u_iram (
	.clk(clk), .a_ce(cen), .a_we(ram_we), .a_addr(ram_addr), .a_wd(ram_dout), .a_rd(ram_din),
	.b_addr(8'd0), .b_rd()
);

reg [7:0] xram [0:255];
reg [7:0] xram_q;
reg       x_lo;
always @(posedge clk) begin
	if (cen) begin
		rom_hi <= rom_addr[15];
		if (x_acc && x_wr && x_addr[15:8] == 8'd0) xram[x_addr[7:0]] <= x_dout;
	end
	xram_q <= xram[x_addr[7:0]];
	x_lo <= x_addr[15:8] == 8'd0;
end
assign x_din = x_lo ? xram_q : u7_qb;

jt8052 u_mcu (
	.rst(rst), .clk(clk), .cen(cen),
	.int0n(1'b1), .int1n(int1n),
	.p0_i(8'hff), .p1_i(p1_i), .p2_i(8'hff), .p3_i(8'hff),
	.p0_o(), .p1_o(p1_o), .p2_o(p2_o), .p3_o(p3_o),
	.rom_data(rom_hi ? 8'hff : u7_qa), .rom_addr(rom_addr),
	.ram_din(ram_din), .ram_dout(ram_dout), .ram_addr(ram_addr), .ram_we(ram_we),
	.x_din(x_din), .x_dout(x_dout), .x_addr(x_addr), .x_wr(x_wr), .x_acc(x_acc),
	.p3_we(p3_we), .p3_latch(p3_latch)
);

endmodule
