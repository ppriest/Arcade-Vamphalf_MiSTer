// The YM2151 + OKI M6295 sound of the vamphalf driver's other boards (sound_ym_oki, vamphalf.cpp:1158):
// both chips on the main CPU's I/O, no sound CPU.
//
//   YM2151   28 MHz / 8 = 3.5 MHz, or 14.318181 MHz / 4 on the SUPLUP board (sound_suplup)   jt51
//   M6295    28 MHz / 16 = 1.75 MHz, or 14.318181 MHz / 8; pin 7 high                      jt6295
//
// Both chips' clocks are fractional enables of clk (56 MHz) from one 32-bit phase accumulator each: the
// enable rate over clk, times 2^32, chosen by xtal14. The M6295's ROM (MAME's "oki1" region) is read from SDRAM at
// SD_SAMPLES through the bridge and the per-channel granule cache (rtl/sound/PROVENANCE.md).
//
// MAME routes the YM2151 at 1.0 to each side and the M6295 at 1.0 to both. Its M6295 reaches full scale with
// one voice at full volume; jt6295's sum is 14 bits with a voice at 12, so it is scaled by 16 before the
// sum, which is clamped to 16 bits.
module vh_ymoki (
	input               clk,
	input               rst,
	input               xtal14,           // the SUPLUP board's 14.318181 MHz clocks
	input               dl,               // the ROM is being downloaded: invalidate the cache

	// main CPU side: one-clock strobes
	input               ym_wr,
	input               ym_a0,
	input       [7:0]   ym_din,
	output      [7:0]   ym_dout,
	input               oki_wr,
	input       [7:0]   oki_din,
	output      [7:0]   oki_dout,
	input       [2:0]   bank,
	input               banked,           // banked_oki_map (vamphalf.cpp:695): 0x20000-0x3ffff is bank * 0x20000 of the region

	// SDRAM port 1: one 64-bit granule per request
	output reg  [26:1]  sd_addr,
	output reg          sd_req,
	input               sd_ack,
	input       [63:0]  sd_dout,

	output signed [15:0] out_l,
	output signed [15:0] out_r
);

`include "vh_sdram_map.svh"

// ---------------------------------------------------------------- clock enables
reg [31:0] acc_ym = 0, acc_oki = 0;
wire [31:0] step_ym  = xtal14 ? 32'h105d_1736 : 32'h1000_0000;    // 3579545.25 Hz, 3.5 MHz
wire [31:0] step_oki = xtal14 ? 32'h082e_8b9b : 32'h0800_0000;    // 1789772.62 Hz, 1.75 MHz
reg        cen_ym = 0, cen_ym2 = 0, cen_oki = 0, ym_half = 0;
always @(posedge clk) begin
	{cen_ym, acc_ym}   <= {1'b0, acc_ym}  + {1'b0, step_ym};
	{cen_oki, acc_oki} <= {1'b0, acc_oki} + {1'b0, step_oki};
	if (cen_ym) ym_half <= ~ym_half;
end
wire cen_ym_p1 = cen_ym && ym_half;

// ---------------------------------------------------------------- YM2151
wire signed [15:0] ym_l, ym_r;
jt51 u_ym (
	.rst(rst), .clk(clk), .cen(cen_ym), .cen_p1(cen_ym_p1),
	.cs_n(~ym_wr), .wr_n(~ym_wr), .a0(ym_a0), .din(ym_din), .dout(ym_dout),
	.ct1(), .ct2(), .irq_n(), .sample(),
	.left(ym_l), .right(ym_r), .xleft(), .xright()
);

// ---------------------------------------------------------------- M6295
wire        [17:0] oki_rom_addr;
wire        [7:0]  oki_rom_data;
wire               oki_rom_ok;
wire signed [13:0] oki_snd;
jt6295 #(.INTERPOL(0)) u_oki (
	.rst(rst), .clk(clk), .cen(cen_oki), .ss(1'b1),
	.wrn(~oki_wr), .din(oki_din), .dout(oki_dout),
	.rom_addr(oki_rom_addr), .rom_data(oki_rom_data), .rom_ok(oki_rom_ok),
	.sound(oki_snd), .sample()
);

wire        br_req, br_valid;
wire [19:0] br_addr;
wire [7:0]  br_data;
wire [19:0] oki_eff = (banked && oki_rom_addr[17]) ? {bank, oki_rom_addr[16:0]} : {2'd0, oki_rom_addr};
oki_rom_bridge u_bridge (
	.clk(clk), .reset(rst),
	.rom_addr(oki_eff[17:0]), .rom_data(oki_rom_data), .rom_ok(oki_rom_ok), .bank(oki_eff[19:18]),
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

// granule fetches on port 1 (toggle protocol; the cache holds g_req until g_valid)
reg sd_busy;
always @(posedge clk) begin
	g_valid <= 1'b0;
	if (rst) begin
		sd_busy <= 1'b0;
		sd_req <= sd_ack;
	end else if (!sd_busy) begin
		if (g_req && !g_valid) begin
			sd_addr <= SD_SAMPLES[26:1] + {1'b0, g_addr[25:1]};
			sd_req <= ~sd_req;
			sd_busy <= 1'b1;
		end
	end else if (sd_req == sd_ack) begin
		g_data <= sd_dout;
		g_valid <= 1'b1;
		sd_busy <= 1'b0;
	end
end

// ---------------------------------------------------------------- mix
wire signed [17:0] oki_x16 = {oki_snd, 4'd0};
wire signed [18:0] sum_l = ym_l + oki_x16;
wire signed [18:0] sum_r = ym_r + oki_x16;
function signed [15:0] clamp16(input signed [18:0] v);
	clamp16 = (v > 19'sd32767) ? 16'sd32767 : (v < -19'sd32768) ? -16'sd32768 : v[15:0];
endfunction
assign out_l = clamp16(sum_l);
assign out_r = clamp16(sum_r);

endmodule
