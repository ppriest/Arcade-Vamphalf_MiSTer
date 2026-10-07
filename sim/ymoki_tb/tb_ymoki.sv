// Bench top for the YM2151 + M6295 board (rtl/sound/vh_ymoki.sv): its ports, and the SDRAM port 1 as
// a fixed-latency model served by main.cpp.
module tb_ymoki (
	input               clk,
	input               rst,
	input               xtal14,
	input               ym_wr,
	input               ym_a0,
	input       [7:0]   ym_din,
	input               oki_wr,
	input       [7:0]   oki_din,
	output      [26:1]  sd_addr,
	output              sd_req,
	input               sd_ack,
	input       [63:0]  sd_dout,
	output signed [15:0] out_l,
	output signed [15:0] out_r
);
vh_ymoki u_snd (
	.clk(clk), .rst(rst), .xtal14(xtal14), .dl(1'b0),
	.ym_wr(ym_wr), .ym_a0(ym_a0), .ym_din(ym_din), .ym_dout(),
	.oki_wr(oki_wr), .oki_din(oki_din), .oki_dout(), .bank(2'd0), .banked(1'b0),
	.sd_addr(sd_addr), .sd_req(sd_req), .sd_ack(sd_ack), .sd_dout(sd_dout),
	.out_l(out_l), .out_r(out_r)
);
endmodule
