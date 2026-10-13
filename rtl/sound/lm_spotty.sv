// Spotty's sound board (limenko.cpp spotty_state): an AT89C4051 at 4 MHz and an M6295 at 4 MHz / 4, pin 7
// high, with no bus between them. The MCU's P1 reads a board latch, not the M6295 or the main CPU's latch:
//
//   P1 write                     the latch takes the value                             audiocpu_p1_w
//   P3 bit 0 falls, bit 7 low    the latch takes the M6295's status                    audiocpu_p3_w
//   P3 bit 1 falls, bit 7 low    the M6295 is written with the latch
//   P3 bit 3 falls               the latch takes the main CPU's sound latch; pending clears
//   P3 read                      bit 2 = no sound latch pending, the rest 0             audiocpu_p3_r
//
// in that order within one P3 write. Both latches are ff after reset (the 8051's reset writes P3 and P1 with ff).
// The MCU is jt8052 with its 4 KB ROM in block RAM (from dl_*), on an enable of 1 in 14 clocks; the M6295
// takes every fourth. The M6295's ROM (MAME's "oki", 256 KB) is read from SDRAM at SAMPLES_BASE through the
// bridge and the per-channel granule cache, as in vh_ymoki.
module lm_spotty #(
	parameter [26:0] SAMPLES_BASE = 27'h0
) (
	input               clk,             // 56 MHz
	input               rst,
	input               dl,              // the ROM is being downloaded: invalidate the cache

	input               dl_we,           // the MCU ROM download, while rst is held
	input       [11:0]  dl_addr,
	input       [7:0]   dl_data,

	input               latch_wr,        // the main CPU's sound latch (0x1400, bits 23:16)
	input       [7:0]   latch_d,

	// SDRAM port 1: one 64-bit granule per request
	output reg  [26:1]  sd_addr,
	output reg          sd_req,
	input               sd_ack,
	input       [63:0]  sd_dout,

	output signed [15:0] out
);

// ---------------------------------------------------------------- clock enables
reg [3:0] cdiv;
reg [1:0] odiv;
reg       mcen, ocen;
always @(posedge clk) begin
	mcen <= 1'b0;
	ocen <= 1'b0;
	if (rst) begin
		cdiv <= 4'd0; odiv <= 2'd0;
	end else if (cdiv == 4'd13) begin
		cdiv <= 4'd0;
		mcen <= 1'b1;
		odiv <= odiv + 2'd1;
		ocen <= odiv == 2'd3;
	end else cdiv <= cdiv + 4'd1;
end

// ---------------------------------------------------------------- AT89C4051
wire [15:0] rom_addr;
wire [7:0]  rom_q, ram_addr, ram_dout, ram_din;
wire        ram_we, p1_we, p3_we;
wire [7:0]  p1_o, p3_latch;

vh_dpram #(.AW(12), .DW(8), .NBE(1)) u_rom (
	.clk(clk), .a_ce(mcen | dl_we), .a_we(dl_we), .a_addr(dl_we ? dl_addr : rom_addr[11:0]),
	.a_wd(dl_data), .a_rd(rom_q),
	.b_addr(12'd0), .b_rd()
);

// internal RAM: read and written on the enable (Limenko.sdc gives the MCU's paths into it two clocks)
vh_dpram #(.AW(8), .DW(8), .NBE(1)) u_iram (
	.clk(clk), .a_ce(mcen), .a_we(ram_we), .a_addr(ram_addr), .a_wd(ram_dout), .a_rd(ram_din),
	.b_addr(8'd0), .b_rd()
);

reg  [7:0] b_p1, b_p3, latch;
reg        pending;

// no external bus on the AT89C4051: MOVX is not used by the firmware
jt8052 u_mcu (
	.rst(rst), .clk(clk), .cen(mcen),
	.int0n(1'b1), .int1n(1'b1),
	.p0_i(8'hff), .p1_i(b_p1), .p2_i(8'hff), .p3_i({5'd0, ~pending, 2'd0}),
	.p0_o(), .p1_o(p1_o), .p2_o(), .p3_o(),
	.rom_data(rom_q), .rom_addr(rom_addr),
	.ram_din(ram_din), .ram_dout(ram_dout), .ram_addr(ram_addr), .ram_we(ram_we),
	.x_din(8'hff), .x_dout(), .x_addr(), .x_wr(), .x_acc(),
	.p3_we(p3_we), .p3_latch(p3_latch), .p1_we(p1_we)
);

// ---------------------------------------------------------------- the board latch
wire [7:0] oki_dout;
reg        oki_wr;
reg  [7:0] oki_din;
wire       f_rd  = b_p3[0] && !p3_latch[0] && !p3_latch[7];
wire       f_wr  = b_p3[1] && !p3_latch[1] && !p3_latch[7];
wire       f_lat = b_p3[3] && !p3_latch[3];
wire [7:0] p1_rd = f_rd ? oki_dout : b_p1;
always @(posedge clk) begin
	oki_wr <= 1'b0;
	if (rst) begin
		b_p1 <= 8'hff; b_p3 <= 8'hff;
		latch <= 8'd0; pending <= 1'b0;
	end else begin
		// p1_we and p3_we are high for the enable after the write, with the SFR value in p1_o and p3_latch
		if (mcen && p1_we) b_p1 <= p1_o;
		if (mcen && p3_we) begin
			b_p3 <= p3_latch;
			oki_wr <= f_wr;
			oki_din <= p1_rd;
			b_p1 <= f_lat ? latch : p1_rd;
			if (f_lat) pending <= 1'b0;
		end
		if (latch_wr) begin latch <= latch_d; pending <= 1'b1; end
	end
end

// ---------------------------------------------------------------- M6295
wire        [17:0] oki_rom_addr;
wire        [7:0]  oki_rom_data;
wire               oki_rom_ok;
wire signed [13:0] oki_snd;
jt6295 #(.INTERPOL(0)) u_oki (
	.rst(rst), .clk(clk), .cen(ocen), .ss(1'b1),
	.wrn(~oki_wr), .din(oki_din), .dout(oki_dout),
	.rom_addr(oki_rom_addr), .rom_data(oki_rom_data), .rom_ok(oki_rom_ok),
	.sound(oki_snd), .sample()
);

wire        br_req, br_valid;
wire [19:0] br_addr;
wire [7:0]  br_data;
oki_rom_bridge u_bridge (
	.clk(clk), .reset(rst),
	.rom_addr(oki_rom_addr), .rom_data(oki_rom_data), .rom_ok(oki_rom_ok), .bank(2'd0),
	.req(br_req), .addr(br_addr), .valid(br_valid), .data(br_data)
);

wire        g_req;
wire [25:0] g_addr;
reg         g_valid;
reg  [63:0] g_data;
sample_cache #(.ENTRIES(8)) u_cache (
	.clk(clk), .reset(rst), .inval(dl),
	.req(br_req), .addr({6'd0, br_addr}), .valid(br_valid), .data(br_data),
	.g_req(g_req), .g_addr(g_addr), .g_valid(g_valid), .g_data(g_data)
);

// granule fetches on port 1 (toggle protocol; the cache holds g_req until its g_valid)
reg sd_busy;
always @(posedge clk) begin
	g_valid <= 1'b0;
	if (rst) begin
		sd_busy <= 1'b0;
		sd_req <= sd_ack;
	end else if (!sd_busy) begin
		if (g_req && !g_valid) begin
			sd_addr <= SAMPLES_BASE[26:1] + {1'b0, g_addr[25:1]};
			sd_req <= ~sd_req;
			sd_busy <= 1'b1;
		end
	end else if (sd_req == sd_ack) begin
		g_data <= sd_dout;
		g_valid <= 1'b1;
		sd_busy <= 1'b0;
	end
end

// MAME routes the M6295 at 1.0: full scale with one voice at full volume. jt6295's sum is 14 bits with a voice
// at 12, so it is scaled by 16 and clamped to 16 bits.
wire signed [17:0] oki_x16 = {oki_snd, 4'd0};
assign out = (oki_x16 > 18'sd32767) ? 16'sd32767 : (oki_x16 < -18'sd32768) ? -16'sd32768 : oki_x16[15:0];

endmodule
