// Vamphalf video: one layer of 16x16 8bpp sprites (MAME vamphalf.cpp draw_sprites), drawn per scanline.
//
// Memory seen by the CPU glue (32-bit words, big-endian halfwords: the first u16 of a dword is [31:16]):
//   sprite RAM   64 KB at 0x40000000, 16384 dwords. Only bands 1..15 (0x0800..0x7fff) are drawn.
//   palette RAM  64 KB at 0x80000000, 16384 dwords, two xRGB555 entries per dword, [31:16] the even one.
// The CPU writes the whole list once per frame in the vertical blanking interval (docs/write_timing_mame.txt).
// The renderer reads a snapshot of bands 1..15 taken after the last write of that pass; the palette is read live.
//
// The graphics ROM is read 16 bytes per sprite row through gfx_*: gfx_req pulses one clock with the byte
// address of the row (code*256 + row*16); gfx_dv then marks four consecutive 32-bit beats, bytes 0-3 first
// (byte 0 in [31:24]).
//
// Timing: ce_pix is one pulse in eight clk. 448 x 264 pixel clocks per frame, visible 320 x 236 at
// x 31..350, y 16..251 (y 20..255 when flipped).

module vh_video (
	input             clk,
	input             rst,
	input      [15:0] code_mask,       // 16'h7fff for the 8 MB graphics ROM (MAME wraps codes by the element count)
	input             palshift,        // colour from word 2 bits 14:8 instead of 6:0 (m_palshift 8: suplup)

	// CPU side, 32-bit words
	input             spr_we,
	input      [3:0]  spr_be,
	input      [13:0] spr_addr,
	input      [31:0] spr_wd,
	output     [31:0] spr_rd,
	input             pal_we,
	input      [3:0]  pal_be,
	input      [13:0] pal_addr,
	input      [31:0] pal_wd,
	output     [31:0] pal_rd,

	input             flip,            // screen flip, from the game's port or the OSD

	// graphics ROM
	output reg        gfx_req,
	input             gfx_rdy,         // the memory takes a request in this clock
	output reg [23:0] gfx_addr,
	input             gfx_dv,
	input      [31:0] gfx_data,

	// video out
	output            ce_pix,
	output reg [7:0]  vid_r,
	output reg [7:0]  vid_g,
	output reg [7:0]  vid_b,
	output reg        hblank,
	output reg        vblank,
	output reg        hsync,
	output reg        vsync,
	output reg [8:0]  hpos,            // position of the pixel on the outputs, 0..447
	output reg [8:0]  vpos,
	output            frame_start,
	output            vblank_start,    // one clock at the start of line 252 (MAME's vblank callback)

	output reg [15:0] dbg_overrun,     // lines whose engine was still running at the next line start
	output reg [12:0] dbg_maxbusy      // longest engine pass, in clk cycles of a 3584-cycle line
);

//------------------------------------------------------------------
// timing
//------------------------------------------------------------------
reg [2:0] pcnt;
reg [8:0] hcnt, vcnt;
assign ce_pix = (pcnt == 3'd0);
wire line_start = (pcnt == 3'd0) && (hcnt == 9'd0);
assign frame_start = line_start && (vcnt == 9'd0);
assign vblank_start = line_start && (vcnt == 9'd252);

always @(posedge clk) begin
	if (rst) begin
		pcnt <= 3'd0; hcnt <= 9'd0; vcnt <= 9'd0;
	end else begin
		pcnt <= pcnt + 3'd1;
		if (pcnt == 3'd7) begin
			if (hcnt == 9'd447) begin
				hcnt <= 9'd0;
				vcnt <= (vcnt == 9'd263) ? 9'd0 : vcnt + 9'd1;
			end else hcnt <= hcnt + 9'd1;
		end
	end
end

// flip is applied from the start of the vertical blanking interval
reg flip_l;
always @(posedge clk) begin
	if (rst) flip_l <= 1'b0;
	else if (pcnt == 3'd0 && hcnt == 9'd0 && vcnt == 9'd252) flip_l <= flip;
end
wire [8:0] vstart = flip_l ? 9'd20 : 9'd16;

//------------------------------------------------------------------
// sprite RAM (live), snapshot, palette
//------------------------------------------------------------------
wire [31:0] cp_d0, cp_d1;
reg  [13:0] cp_addr;
vh_ram_be #(.AW(14)) u_spr (
	.clk(clk),
	.a_we(spr_we), .a_be(spr_be), .a_addr(spr_addr), .a_wd(spr_wd), .a_rd(spr_rd),
	.b_addr(cp_addr), .b_rd(cp_d0)
);
assign cp_d1 = cp_d0;

// the last dword of band 15 is the last write of the CPU's list pass
reg        list_ready;
reg        cp_run;
reg [12:0] cp_a;             // dwords issued, 0..7679 (bands 1..15 start at dword 512)
reg [12:0] cp_r;             // dwords arrived
reg        cp_v1, cp_v2;
reg [31:0] cp_hi;
reg        sn_we;
reg [11:0] sn_wa;
reg [63:0] sn_wd;

wire in_copy_window = (vcnt >= 9'd252) || (vcnt <= 9'd8);

always @(posedge clk) begin
	sn_we <= 1'b0;
	cp_v1 <= 1'b0;
	cp_v2 <= cp_v1;
	if (rst) begin
		list_ready <= 1'b0; cp_run <= 1'b0; cp_a <= 13'd0; cp_r <= 13'd0; cp_v2 <= 1'b0;
	end else begin
		if (spr_we && spr_addr == 14'h1fff) list_ready <= 1'b1;
		if (!cp_run) begin
			if (list_ready && in_copy_window) begin
				cp_run <= 1'b1; cp_a <= 13'd0; cp_r <= 13'd0; list_ready <= 1'b0;
			end
		end else begin
			// address stream, one dword per clock; data arrives two clocks later
			if (cp_a != 13'd7680) begin
				cp_addr <= 14'd512 + cp_a[12:0];
				cp_a <= cp_a + 13'd1;
				cp_v1 <= 1'b1;
			end
			if (cp_v2) begin
				cp_r <= cp_r + 13'd1;
				if (!cp_r[0]) cp_hi <= cp_d0;
				else begin
					sn_we <= 1'b1; sn_wa <= cp_r[12:1]; sn_wd <= {cp_hi, cp_d0};
				end
				if (cp_r == 13'd7679) cp_run <= 1'b0;
			end
		end
	end
end

reg  [11:0] sn_ra;
wire [63:0] sn_rd;
vh_sdp #(.AW(12), .DW(64)) u_snap (
	.clk(clk), .we(sn_we), .wa(sn_wa), .wd(sn_wd), .ra(sn_ra), .rd(sn_rd)
);

reg  [13:0] pv_addr;
wire [31:0] pv_rd;
vh_ram_be #(.AW(14)) u_pal (
	.clk(clk),
	.a_we(pal_we), .a_be(pal_be), .a_addr(pal_addr), .a_wd(pal_wd), .a_rd(pal_rd),
	.b_addr(pv_addr), .b_rd(pv_rd)
);

//------------------------------------------------------------------
// line engine: renders target line T = vcnt + 1 during line vcnt
//------------------------------------------------------------------
wire [8:0] tline = (vcnt == 9'd263) ? 9'd0 : vcnt + 9'd1;
wire       t_active = (tline >= vstart) && (tline < vstart + 9'd236);
// band 1..15 for the strip of the target line
wire [3:0] t_strip = tline[7:4];
wire [3:0] t_band  = flip_l ? t_strip : (4'd16 - t_strip);

reg        eng_run;
reg [12:0] busy_cnt;
reg [8:0]  e_idx;            // next entry to read
reg        sc_v, sc_v1;      // entry data arrives this clock (sc_v) / next clock (sc_v1)
reg        eng_t0;           // buffer written by the engine, tline[0]
reg [8:0]  eng_t;            // target line of the running pass

// FIFO of sprites that hit the line
localparam FD = 16;
(* ramstyle = "logic" *) reg [38:0] fifo [0:FD-1];
reg [4:0]  f_wr, f_rd;
wire [4:0] f_cnt = f_wr - f_rd;
wire       f_full  = (f_cnt >= FD - 3);
wire       f_empty = (f_cnt == 5'd0);

// decode of the entry that arrives (registered snapshot output)
wire [15:0] w0 = sn_rd[63:48], w1 = sn_rd[47:32], w2 = sn_rd[31:16], w3 = sn_rd[15:0];
wire        hide  = w0[8];
wire [10:0] y_top = flip_l ? {3'b0, w0[7:0]} : (11'd256 - {3'b0, w0[7:0]});
wire [10:0] rrow  = {2'b0, eng_t} - y_top;
wire        hit   = sc_v && !hide && (rrow[10:4] == 7'd0);
wire        fy_e  = w0[14] ^ flip_l;
wire        fx_e  = w0[15] ^ flip_l;
wire [3:0]  srow  = fy_e ? ~rrow[3:0] : rrow[3:0];
wire [10:0] xs    = {2'b0, w3[8:0]};
wire [10:0] x_pos = flip_l ? (11'd366 - xs) : xs;
wire [38:0] f_in  = {w1 & code_mask, palshift ? w2[14:8] : w2[6:0], x_pos, fx_e, srow};   // 16 + 7 + 11 + 1 + 4

// fetch: requests go out back to back (up to four in flight), rows come back in order
(* ramstyle = "logic" *) reg [38:0]  mf [0:3];                 // meta of the requests in flight
reg [2:0]   mf_wr, mf_rd;
wire [2:0]  mf_cnt = mf_wr - mf_rd;
reg [1:0]   f_beat;
reg [95:0]  f_acc;
(* ramstyle = "logic" *) reg [127:0] rf_row [0:3];             // rows waiting for the draw stage
reg [38:0]  rf_meta [0:3];
reg [2:0]   rf_wr, rf_rd;
wire [2:0]  rf_cnt = rf_wr - rf_rd;
wire        f_idle = (mf_cnt == 3'd0) && (rf_cnt == 3'd0);
// draw stage
reg         d_busy;
reg [4:0]   d_c;
reg [127:0] d_row;
reg [10:0]  d_x;
reg [6:0]   d_color;
reg         d_fx;


// line buffers: two, 512 x 15
reg         lb_a_we;
reg         lb_a_buf;
reg  [8:0]  lb_a_addr;
reg  [14:0] lb_a_wd;
wire [14:0] lb_b_rd [0:1];
reg  [8:0]  lb_b_addr;
reg         lb_b_buf;
reg         lb_b_we;
reg  [14:0] lb_b_wd;

vh_tdp #(.AW(9), .DW(15)) u_lb0 (
	.clk(clk),
	.a_we(lb_a_we && !lb_a_buf), .a_addr(lb_a_addr), .a_wd(lb_a_wd),
	.b_we(lb_b_we && !lb_b_buf), .b_addr(lb_b_addr), .b_wd(lb_b_wd), .b_rd(lb_b_rd[0])
);
vh_tdp #(.AW(9), .DW(15)) u_lb1 (
	.clk(clk),
	.a_we(lb_a_we && lb_a_buf), .a_addr(lb_a_addr), .a_wd(lb_a_wd),
	.b_we(lb_b_we && lb_b_buf), .b_addr(lb_b_addr), .b_wd(lb_b_wd), .b_rd(lb_b_rd[1])
);

// draw: pixel c of the row
wire [10:0] d_col_s = d_x + {6'b0, d_c[3:0]} - 11'd31;
wire [3:0]  d_src   = d_fx ? ~d_c[3:0] : d_c[3:0];
wire [7:0]  d_pen   = d_row[127 - 8*d_src -: 8];

always @(posedge clk) begin
	gfx_req <= 1'b0;
	lb_a_we <= 1'b0;
	if (rst) begin
		eng_run <= 1'b0; f_wr <= 5'd0; f_rd <= 5'd0; mf_wr <= 3'd0; mf_rd <= 3'd0; rf_wr <= 3'd0; rf_rd <= 3'd0; f_beat <= 2'd0; d_busy <= 1'b0; sc_v <= 1'b0; sc_v1 <= 1'b0;
		dbg_overrun <= 16'd0; dbg_maxbusy <= 13'd0; busy_cnt <= 13'd0;
	end else begin
		if (eng_run) busy_cnt <= busy_cnt + 13'd1;
		if (line_start) begin
			busy_cnt <= 13'd0;
			// start (or abort and restart) the pass for the next line
			if (eng_run) dbg_overrun <= dbg_overrun + 16'd1;
			eng_run <= t_active;
			e_idx <= 9'd0; sc_v <= 1'b0; sc_v1 <= 1'b0;
			f_wr <= 5'd0; f_rd <= 5'd0; mf_wr <= 3'd0; mf_rd <= 3'd0; rf_wr <= 3'd0; rf_rd <= 3'd0; f_beat <= 2'd0; d_busy <= 1'b0;
			eng_t <= tline; eng_t0 <= tline[0];
		end else if (eng_run) begin
			// scan: one entry per clock while the FIFO has room
			sc_v1 <= 1'b0;
			sc_v <= sc_v1;
			if (e_idx < 9'd256 && !f_full) begin
				sn_ra <= {t_band - 4'd1, e_idx[7:0]};
				e_idx <= e_idx + 9'd1;
				sc_v1 <= 1'b1;
			end
			if (hit) begin
				fifo[f_wr[3:0]] <= f_in;
				f_wr <= f_wr + 5'd1;
			end

			// fetch: issue
			if (!f_empty && (mf_cnt + rf_cnt) < 4'd4 && gfx_rdy) begin
				mf[mf_wr[1:0]] <= fifo[f_rd[3:0]];
				mf_wr <= mf_wr + 3'd1;
				f_rd <= f_rd + 5'd1;
				gfx_req <= 1'b1;
				gfx_addr <= {fifo[f_rd[3:0]][38:23], fifo[f_rd[3:0]][3:0], 4'b0000};
			end
			// fetch: collect four beats into a row
			if (gfx_dv) begin
				f_acc <= {f_acc[63:0], gfx_data};
				f_beat <= f_beat + 2'd1;
				if (f_beat == 2'd3) begin
					rf_row[rf_wr[1:0]] <= {f_acc, gfx_data};
					rf_meta[rf_wr[1:0]] <= mf[mf_rd[1:0]];
					rf_wr <= rf_wr + 3'd1;
					mf_rd <= mf_rd + 3'd1;
				end
			end
			// hand a row to the draw stage
			if (!d_busy && rf_cnt != 3'd0) begin
				d_row <= rf_row[rf_rd[1:0]];
				d_color <= rf_meta[rf_rd[1:0]][22:16]; d_x <= rf_meta[rf_rd[1:0]][15:5]; d_fx <= rf_meta[rf_rd[1:0]][4];
				d_c <= 5'd0; d_busy <= 1'b1;
				rf_rd <= rf_rd + 3'd1;
			end

			// draw
			if (d_busy) begin
				lb_a_buf <= eng_t0;
				lb_a_addr <= d_col_s[8:0];
				lb_a_wd <= {d_color, d_pen};
				lb_a_we <= (d_pen != 8'd0) && (d_col_s[10:9] == 2'b00) && (d_col_s[8:0] < 9'd320);
				d_c <= d_c + 5'd1;
				if (d_c == 5'd15) d_busy <= 1'b0;
			end

			// done when everything has drained
			if (e_idx == 9'd256 && !sc_v && !sc_v1 && f_empty && f_idle && !d_busy) begin
				eng_run <= 1'b0;
				if (busy_cnt > dbg_maxbusy) dbg_maxbusy <= busy_cnt;
			end
		end
	end
end

//------------------------------------------------------------------
// scan-out. One pixel is eight clocks; the pipeline for the pixel at hcnt starts at pcnt 0:
//   0: line buffer address registered   2: line buffer data, palette address registered, entry cleared
//   4: palette data                     5: output registers loaded (stable until the next pixel's 5)
// Pixel x of line y comes from line buffer y[0].
//------------------------------------------------------------------
wire        y_active = (vcnt >= vstart) && (vcnt < vstart + 9'd236);
wire        x_active = (hcnt >= 9'd31) && (hcnt <= 9'd350);
wire        hs_w = (hcnt >= 9'd376) && (hcnt < 9'd408);
wire        vs_w = (vcnt >= 9'd256) && (vcnt < 9'd259);

reg         so_buf;
reg  [8:0]  so_addr;
reg         so_lsb;
wire [31:0] pv_q = pv_rd;
wire [15:0] pal_ent = so_lsb ? pv_q[15:0] : pv_q[31:16];

function [7:0] p5(input [4:0] v);
	p5 = {v, v[4:2]};
endfunction

always @(posedge clk) begin
	lb_b_we <= 1'b0;
	if (pcnt == 3'd0) begin
		so_buf <= vcnt[0];
		so_addr <= hcnt - 9'd31;
		lb_b_buf <= vcnt[0];
		lb_b_addr <= hcnt - 9'd31;
	end
	if (pcnt == 3'd2) begin
		// the entry is read; clear it for the next time this buffer is written
		pv_addr <= (x_active && y_active) ? lb_b_rd[so_buf][14:1] : 14'd0;
		so_lsb <= (x_active && y_active) ? lb_b_rd[so_buf][0] : 1'b0;
		lb_b_buf <= so_buf; lb_b_addr <= so_addr; lb_b_wd <= 15'd0;
		lb_b_we <= x_active && y_active;
	end
	if (pcnt == 3'd5) begin
		if (x_active && y_active) begin
			vid_r <= p5(pal_ent[14:10]);
			vid_g <= p5(pal_ent[9:5]);
			vid_b <= p5(pal_ent[4:0]);
		end else begin
			vid_r <= 8'd0; vid_g <= 8'd0; vid_b <= 8'd0;
		end
		hblank <= !x_active;
		vblank <= !y_active;
		hsync <= hs_w;
		vsync <= vs_w;
		hpos <= hcnt;
		vpos <= vcnt;
	end
end

endmodule


// 4 byte-lane dual-port RAM: port A reads and writes (CPU), port B reads (rtl/memory/vh_dpram.sv).
module vh_ram_be #(parameter AW = 14) (
	input             clk,
	input             a_we,
	input      [3:0]  a_be,
	input      [AW-1:0] a_addr,
	input      [31:0] a_wd,
	output     [31:0] a_rd,
	input      [AW-1:0] b_addr,
	output     [31:0] b_rd
);
vh_dpram #(.AW(AW), .DW(32), .NBE(4)) u_ram (
	.clk(clk), .a_ce(1'b1), .a_we(a_we ? a_be : 4'd0), .a_addr(a_addr), .a_wd(a_wd), .a_rd(a_rd),
	.b_addr(b_addr), .b_rd(b_rd)
);
endmodule


// simple dual-port RAM, one write port and one read port
module vh_sdp #(parameter AW = 12, parameter DW = 64) (
	input             clk,
	input             we,
	input      [AW-1:0] wa,
	input      [DW-1:0] wd,
	input      [AW-1:0] ra,
	output reg [DW-1:0] rd
);
reg [DW-1:0] mem [0:(1<<AW)-1];
always @(posedge clk) if (we) mem[wa] <= wd;
always @(posedge clk) rd <= mem[ra];
endmodule


// true dual-port: A writes, B reads and writes
module vh_tdp #(parameter AW = 9, parameter DW = 15) (
	input             clk,
	input             a_we,
	input      [AW-1:0] a_addr,
	input      [DW-1:0] a_wd,
	input             b_we,
	input      [AW-1:0] b_addr,
	input      [DW-1:0] b_wd,
	output reg [DW-1:0] b_rd
);
(* ramstyle = "M10K, no_rw_check" *) reg [DW-1:0] mem [0:(1<<AW)-1];
always @(posedge clk) if (a_we) mem[a_addr] <= a_wd;
always @(posedge clk) begin
	if (b_we) mem[b_addr] <= b_wd;
	b_rd <= mem[b_addr];
end
endmodule
