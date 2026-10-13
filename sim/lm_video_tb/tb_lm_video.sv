// Limenko video bench: lm_video with its graphics port answered from an array main.cpp fills (the download image's
// graphics) after LAT clocks, and its DDR3 port by a model of MiSTer's Avalon port (reads return DLAT clocks after
// the request, a beat a clock; writes and bursts are taken every clock). main.cpp loads a capture's RAMs through the
// CPU ports and issues the draw commands.
module tb_lm_video #(parameter LAT = 10, parameter DLAT = 40) (
	input             clk,
	input             rst,
	input      [18:0] tile_count,
	input             tile_pow2,
	input             gfx4,
	input      [25:0] gfx_size,
	input             v0_we,
	input      [13:0] v0_addr,
	input      [31:0] v0_wd,
	input             v1_we,
	input      [13:0] v1_addr,
	input      [31:0] v1_wd,
	input             spr_cmd,
	output            v1_wait,
	output            ce_pix,
	output     [7:0]  vid_r,
	output     [7:0]  vid_g,
	output     [7:0]  vid_b,
	output            hblank,
	output            vblank,
	output            frame_start,
	output            vblank_start,
	output     [15:0] dbg_overrun,
	output     [15:0] dbg_spr_late,
	output     [15:0] dbg_fb_late
);

// the graphics, 8-byte granules from LM_GFX (main.cpp writes it)
reg  [63:0] gfx [0:(1 << 22) - 1];
wire [26:1] gfx_addr;
wire        gfx_req;
reg         gfx_ack = 1'b0;
reg  [63:0] gfx_dout;
reg  [7:0]  cnt = 8'd0;
always @(posedge clk) begin
	if (gfx_req != gfx_ack) begin
		cnt <= cnt + 8'd1;
		if (cnt == LAT) begin
			gfx_dout <= gfx[(gfx_addr[26:3] - 24'h1c0000) & 24'h3fffff];   // LM_GFX 0xe00000 in granules
			gfx_ack <= gfx_req;
			cnt <= 8'd0;
		end
	end
end

// DDR3: 64K words from FB_BASE
wire [7:0]  d_cnt, d_be;
wire [28:0] d_addr;
wire [63:0] d_din;
wire        d_we, d_rd;
reg  [63:0] ddr [0:65535];
reg  [63:0] d_dout;
reg         d_ready = 1'b0;
reg  [15:0] wa, ra;
reg  [7:0]  wleft = 8'd0, rleft = 8'd0, rlat = 8'd0;
integer     bi;
always @(posedge clk) begin
	d_ready <= 1'b0;
	if (d_we) begin
		for (bi = 0; bi < 8; bi = bi + 1)
			if (d_be[bi]) ddr[wleft == 8'd0 ? d_addr[15:0] : wa][8 * bi +: 8] <= d_din[8 * bi +: 8];
		if (wleft == 8'd0) begin wleft <= d_cnt - 8'd1; wa <= d_addr[15:0] + 16'd1; end
		else begin wleft <= wleft - 8'd1; wa <= wa + 16'd1; end
	end
	if (d_rd) begin ra <= d_addr[15:0]; rleft <= d_cnt; rlat <= DLAT; end
	else if (rleft != 8'd0) begin
		if (rlat != 8'd0) rlat <= rlat - 8'd1;
		else begin d_dout <= ddr[ra]; d_ready <= 1'b1; ra <= ra + 16'd1; rleft <= rleft - 8'd1; end
	end
end

lm_video u_video (
	.clk(clk), .rst(rst), .tile_count(tile_count), .tile_pow2(tile_pow2), .gfx4(gfx4), .gfx_size(gfx_size), .flip(1'b0),
	.v0_we(v0_we), .v0_be(4'hf), .v0_addr(v0_addr), .v0_wd(v0_wd), .v0_rd(),
	.v1_we(v1_we), .v1_be(4'hf), .v1_addr(v1_addr), .v1_wd(v1_wd), .v1_rd(),
	.spr_cmd(spr_cmd), .spr_bit(), .v1_wait(v1_wait),
	.gfx_addr(gfx_addr), .gfx_req(gfx_req), .gfx_ack(gfx_ack), .gfx_dout(gfx_dout),
	.DDRAM_BURSTCNT(d_cnt), .DDRAM_ADDR(d_addr), .DDRAM_DIN(d_din), .DDRAM_BE(d_be), .DDRAM_WE(d_we),
	.DDRAM_RD(d_rd), .DDRAM_BUSY(1'b0), .DDRAM_DOUT(d_dout), .DDRAM_DOUT_READY(d_ready),
	.ce_pix(ce_pix), .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
	.hblank(hblank), .vblank(vblank), .hsync(), .vsync(),
	.frame_start(frame_start), .vblank_start(vblank_start), .dbg_overrun(dbg_overrun),
	.dbg_spr_late(dbg_spr_late), .dbg_fb_late(dbg_fb_late)
);

endmodule
