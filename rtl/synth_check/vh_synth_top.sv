// Standalone synthesis wrapper for the video block: ports straight to (virtual) pins.
module vh_synth_top (
	input clk, input rst, input [15:0] code_mask, input palshift, input code17,
	input spr_we, input [3:0] spr_be, input [13:0] spr_addr, input [31:0] spr_wd, output [31:0] spr_rd,
	input pal_we, input [3:0] pal_be, input [13:0] pal_addr, input [31:0] pal_wd, output [31:0] pal_rd,
	input flip,
	output gfx_req, input gfx_rdy, output [24:0] gfx_addr, input gfx_dv, input [31:0] gfx_data,
	output ce_pix, output [7:0] vid_r, output [7:0] vid_g, output [7:0] vid_b,
	output hblank, output vblank, output hsync, output vsync,
	output [8:0] hpos, output [8:0] vpos, output frame_start, output vblank_start,
	output [15:0] dbg_overrun, output [12:0] dbg_maxbusy
);
vh_video v (.*);
endmodule
