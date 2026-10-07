// Direct-mapped cache, 16-byte lines, for the E1's work RAM and program ROM in SDRAM (vh_cpumem).
//
// One port into each RAM, used in turn by the owner (vh_cpumem sequences them):
//   lookup  la (byte address in the cached space) presented in a cycle; in the next cycle hit and
//           q (the 8-byte half of the line holding la) are valid. The tag is compared against the
//           address registered with the lookup.
//   fill    fill_we writes the 8-byte half fill_half of the line at fa; fill_tag with it marks the
//           line valid (the owner writes the tag with the second half)
//   store   st_we writes st_be lanes of st_d into the half at la (the owner asserts it only on a hit,
//           in the cycle the hit is valid, with la held)
//   sweep   while sweep is high the tag at sw_idx is cleared; the owner runs sw_idx over every line
//
// Byte order inside a half: byte 0 of the half in [63:56] (big-endian, as the CPU sees it).
// Sizes (AW = address bits of the cached space, LW = line-index bits): data 2^(LW+1) x 64, tags
// 2^LW x (AW-LW-4+1).

module vh_cache #(
	parameter AW = 22,
	parameter LW = 10
) (
	input             clk,
	input             sweep,
	input  [LW-1:0]   sw_idx,

	input  [AW-1:0]   la,
	output            hit,
	output [63:0]     q,

	input             fill_we,
	input             fill_tag,
	input  [AW-1:0]   fa,
	input             fill_half,
	input  [63:0]     fill_d,

	input             st_we,
	input  [7:0]      st_be,
	input  [63:0]     st_d
);

localparam TW = AW - LW - 4;

reg  [AW-1:0] la_r;
always @(posedge clk) la_r <= la;

// tags: {valid, tag}
wire [LW-1:0] t_addr = sweep ? sw_idx : (fill_we ? fa[LW+3:4] : la[LW+3:4]);
wire          t_we   = sweep || (fill_we && fill_tag);
wire [TW:0]   t_wd   = sweep ? {(TW+1){1'b0}} : {1'b1, fa[AW-1:LW+4]};
wire [TW:0]   t_q;
vh_cache_ram #(.AW(LW), .DW(TW + 1)) u_tag (.clk(clk), .addr(t_addr), .we(t_we),
	.be(1'b1), .wd(t_wd), .q(t_q));

// data: 8 byte lanes, lane 7 = [63:56] = byte 0 of the half
wire [LW:0]   d_addr = fill_we ? {fa[LW+3:4], fill_half} : la[LW+3:3];
wire [7:0]    d_be   = fill_we ? 8'hff : st_be;
wire [63:0]   d_wd   = fill_we ? fill_d : st_d;
vh_cache_ram #(.AW(LW + 1), .DW(64), .NB(8)) u_data (.clk(clk), .addr(d_addr), .we(fill_we || st_we),
	.be(d_be), .wd(d_wd), .q(q));

assign hit = t_q[TW] && (t_q[TW-1:0] == la_r[AW-1:LW+4]);

endmodule


// single-port RAM with per-lane write enables (NB lanes of DW/NB bits), registered read
module vh_cache_ram #(parameter AW = 10, parameter DW = 64, parameter NB = 1) (
	input               clk,
	input  [AW-1:0]     addr,
	input               we,
	input  [NB-1:0]     be,
	input  [DW-1:0]     wd,
	output [DW-1:0]     q
);
localparam LWD = DW / NB;
genvar i;
generate
	for (i = 0; i < NB; i = i + 1) begin : lane
		reg [LWD-1:0] mem [0:(1<<AW)-1];
		reg [LWD-1:0] qr;
		always @(posedge clk) begin
			if (we && be[i]) mem[addr] <= wd[LWD*i +: LWD];
			qr <= mem[addr];
		end
		assign q[LWD*i +: LWD] = qr;
	end
endgenerate
endmodule
