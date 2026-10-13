// The Limenko sprite draw engine (limenko.cpp spriteram_buffer_w, draw_sprites): at each draw command it copies the
// list, clears the back buffer of the DDR3 frame buffer (lm_fb) and draws the list into it; the buffers swap at the
// next interrupt once the draw is written (MAME shows the bitmap drawn at the last command).
//
// The list: entries 0..count (count from the command before) of the bank the command selects, two dwords each; an
// entry past the 8 KB sprite RAM reads 0 (MAME reads past its share). The CPU's writes to the v1 window wait while
// it is copied (v1_wait): the games rewrite the drawn bank from the line of the command.
// Order: MAME draws entries in order into a 512 x 512 bitmap with a priority bitmap, writing a pixel where the
// bitmap's priority is below the sprite's (1 below fg, 2 above all), so the first entry wins within a priority. The
// same picture comes from overwriting: the priority-1 entries from last to first, then the priority-2 entries
// from last to first.
// An entry: word 0 bit 31 enable, 24:16 x, 27:25 width / 8 - 1, 28 flip x, 8:0 y, 11:9 height / 8 - 1, 12 flip y;
// word 1 18:0 the code (byte offset / 64 into the graphics), 31:28 colour, 26 below fg. Skipped when the code plus
// width * height passes the graphics' end. Positions wrap at 512 (MAME draws at x, x - 512 and y, y - 512): a pixel
// is drawn at ((x + c) & 511, (y + r) & 511) when that is inside 384 x 240.
// A visible row of the sprite is read from SDRAM (gfx_*, 8-byte granules) into one of two row slots while the
// other is drawn, two clocks a pixel; pen 0 is transparent; four pixels to a DDR3 word with byte enables.
// spotty's graphics are 4bpp, the first pixel in bits 3:0 of a byte: pixel offset o of the 8bpp space is
// nibble o & 1 of byte o >> 1.

module lm_sprites #(
	parameter [26:0] GFX_BASE = 27'h0e00000
) (
	input             clk,
	input             rst,
	input      [25:0] gfx_size,         // bytes of the 8bpp graphics space
	input             gfx4,

	input             cmd,              // the draw command
	input             cmd_bank,         // the bank it selects
	input      [9:0]  cmd_count,        // the count latched at the command before
	input             vbl,              // the interrupt: the swap point
	output reg        front,            // the buffer shown
	output reg        shown,            // a draw has been swapped in since reset: the front buffer holds one

	output reg [10:0] sr_addr,          // sprite RAM, data a clock after the address
	input      [31:0] sr_q,
	output            v1_wait,

	output reg [26:1] gfx_addr,
	output reg        gfx_req = 1'b0,
	input             gfx_ack,
	input      [63:0] gfx_dout,

	output reg        q_we,
	output reg        q_clr,
	output            q_buf,
	output reg [14:0] q_addr,
	output reg [63:0] q_data,
	output reg [7:0]  q_be,
	input             q_room,
	input             q_empty,

	output reg [15:0] dbg_late          // interrupts at which the last command's draw was not finished
);

// ---------------------------------------------------------------- list copy
reg  [31:0] lst [0:2047];
reg  [10:0] lst_ra;
reg  [31:0] lst_q;
reg         cp_run;
reg  [11:0] cp_i, cp_n;             // dword i of n = 2 * count + 2
reg  [11:0] cp_base;                // the bank's first dword: bank * 1024
reg         cp_v1, cp_v2, cp_in1, cp_in2;
reg  [10:0] cp_i1, cp_i2;
wire [11:0] cp_phys = cp_base + cp_i;
always @(posedge clk) begin
	if (cp_v2) lst[cp_i2] <= cp_in2 ? sr_q : 32'd0;
	lst_q <= lst[lst_ra];
end
assign v1_wait = cp_run;

// ---------------------------------------------------------------- the walk and the row fetch
localparam [3:0] W_IDLE = 0, W_COPY = 1, W_CLR = 2, W_ENT = 3, W_RD1 = 4, W_W0 = 5, W_W1 = 6, W_DEC = 7,
                 W_ROW = 8, W_SLOT = 9, W_GREQ = 10, W_GWAIT = 11, W_FIN = 12;
reg  [3:0]  w_st;
reg         w_buf;                  // the buffer being drawn
reg  [9:0]  w_count;
reg  [1:0]  w_pass;                 // 1, then 2
reg  [9:0]  w_i;                    // the entry, from count down to 0
reg  [31:0] w0, w1;
reg  [6:0]  s_w, s_h;               // pixels
reg  [8:0]  s_x, s_y;
reg         s_fx, s_fy;
reg  [3:0]  s_col;
reg  [5:0]  s_r;                    // the row
reg  [25:0] s_row;                  // the row's offset in the 8bpp space
reg  [25:0] s_end;                  // code + width * height
wire [8:0]  s_sy = s_y + {3'd0, s_r};    // the row on the 512-line bitmap
reg         restart;

// width * height / 64 for widths and heights of 1..8 units of 8
function [6:0] units(input [2:0] a, input [2:0] b);
	reg [6:0] t;
	integer k;
	begin
		t = 7'd0;
		for (k = 0; k < 8; k = k + 1) if (k <= b) t = t + {4'd0, a} + 7'd1;
		units = t;
	end
endfunction

// row slots: two of 8 granules, filled by the fetch, drawn by the emitter
reg         sl_full [0:1];
reg         sl_f;                   // the slot the fetch fills
reg  [8:0]  sl_y   [0:1];
reg  [8:0]  sl_x   [0:1];
reg  [6:0]  sl_w   [0:1];
reg         sl_fx  [0:1];
reg  [3:0]  sl_col [0:1];
reg  [1:0]  sl_pri [0:1];
reg  [2:0]  sl_off [0:1];           // the row's first byte within its first granule
(* ramstyle = "logic" *) reg [63:0] rb [0:15];   // read in the clock the emitter asks
reg  [26:0] f_a;                    // the row's first byte in SDRAM
reg  [2:0]  f_g, f_n;               // granule f_g of f_n
wire [25:0] row_packed = gfx4 ? {1'b0, s_row[25:1]} : s_row;
wire [6:0]  row_bytes  = gfx4 ? {1'b0, s_w[6:1]} : s_w;
wire [26:0] f_first    = GFX_BASE + {1'b0, row_packed};
// granules covering bytes f_first .. f_first + row_bytes - 1
wire [6:0]  f_span     = {4'd0, f_first[2:0]} + row_bytes + 7'd7;   // granules: f_span / 8
wire [2:0]  f_gran     = f_span[6:3] == 4'd8 ? 3'd0 : f_span[5:3];   // the granule count, 8 as 0 (f_n wraps to 7)

reg  e_done;                        // the emitter has nothing left of the walk
reg  draw_end;                      // the walk has ended; done once the emitter and the queue drain
reg  pend_swap;

always @(posedge clk) begin
	q_clr <= 1'b0;
	cp_v1 <= 1'b0;
	cp_v2 <= cp_v1;
	cp_in2 <= cp_in1;
	cp_i2 <= cp_i1;
	if (rst) begin
		w_st <= W_IDLE;
		cp_run <= 1'b0;
		front <= 1'b0;
		shown <= 1'b0;
		pend_swap <= 1'b0;
		draw_end <= 1'b0;
		restart <= 1'b0;
		sl_full[0] <= 1'b0; sl_full[1] <= 1'b0;
		dbg_late <= 16'd0;
		gfx_req <= gfx_ack;
	end else begin
		if (vbl) begin
			if (pend_swap) begin front <= w_buf; shown <= 1'b1; pend_swap <= 1'b0; end
			else if (w_st != W_IDLE) dbg_late <= dbg_late + 16'd1;
		end
		if (draw_end && e_done && q_empty && !q_we) begin
			draw_end <= 1'b0;
			pend_swap <= 1'b1;
		end
		if (cmd) begin
			restart <= 1'b1;
			w_count <= cmd_count;
			cp_n <= {1'b0, cmd_count, 1'b0} + 12'd2;
			cp_i <= 12'd0;
			cp_base <= {1'b0, cmd_bank, 10'd0};
			pend_swap <= 1'b0;
			draw_end <= 1'b0;
		end
		// a command restarts the walk once no granule is in flight
		if (restart && !cmd && w_st != W_GWAIT) begin
			restart <= 1'b0;
			cp_run <= 1'b1;
			sl_full[0] <= 1'b0; sl_full[1] <= 1'b0;
			sl_f <= 1'b0;
			w_buf <= !front;
			w_st <= W_COPY;
		end else case (w_st)
			W_COPY: begin
				// dword cp_i: physical index bank * 1024 + i; data written two clocks on (cp_v2)
				if (cp_i != cp_n) begin
					sr_addr <= cp_phys[10:0];
					cp_v1 <= 1'b1;
					cp_in1 <= !cp_phys[11];
					cp_i1 <= cp_i[10:0];
					cp_i <= cp_i + 12'd1;
				end else if (!cp_v1 && !cp_v2) begin
					cp_run <= 1'b0;
					w_st <= W_CLR;
				end
			end
			W_CLR: if (q_room) begin
				q_clr <= 1'b1;
				w_pass <= 2'd1;
				w_i <= w_count;
				w_st <= W_ENT;
			end
			W_ENT: begin lst_ra <= {w_i, 1'b0}; w_st <= W_RD1; end
			W_RD1: begin lst_ra <= {w_i, 1'b1}; w_st <= W_W0; end
			W_W0: begin w0 <= lst_q; w_st <= W_W1; end
			W_W1: begin w1 <= lst_q; w_st <= W_DEC; end
			W_DEC: begin
				s_x <= w0[24:16]; s_y <= w0[8:0];
				s_w <= {w0[27:25], 3'b000} + 7'd8;
				s_h <= {w0[11:9], 3'b000} + 7'd8;
				s_fx <= w0[28]; s_fy <= w0[12];
				s_col <= w1[31:28];
				s_r <= 6'd0;
				s_end <= {1'b0, w1[18:0], 6'd0} + {13'd0, units(w0[27:25], w0[11:9]), 6'd0};
				// flip y walks the rows from the last: code + width * (height - 1)
				s_row <= w0[12] ? {1'b0, w1[18:0], 6'd0} + {13'd0, units(w0[27:25], w0[11:9]), 6'd0} - {16'd0, w0[27:25], 3'b000} - 26'd8
				                : {1'b0, w1[18:0], 6'd0};
				if (w0[31] && (w1[26] ? 2'd1 : 2'd2) == w_pass &&
				    {1'b0, w1[18:0], 6'd0} + {13'd0, units(w0[27:25], w0[11:9]), 6'd0} <= gfx_size)
					w_st <= W_ROW;
				else w_st <= W_FIN;
			end
			W_ROW: begin
				// row s_r: on screen at (y + r) & 511 if that is below 240
				if (s_sy < 9'd240 && !sl_full[sl_f]) begin
					sl_y[sl_f] <= s_sy;
					sl_x[sl_f] <= s_x;
					sl_w[sl_f] <= s_w;
					sl_fx[sl_f] <= s_fx;
					sl_col[sl_f] <= s_col;
					sl_pri[sl_f] <= w_pass;
					sl_off[sl_f] <= f_first[2:0];
					f_a <= {f_first[26:3], 3'b000};
					f_g <= 3'd0;
					f_n <= f_gran - 3'd1;
					w_st <= W_GREQ;
				end else if (s_sy >= 9'd240) begin
					// an invisible row
					s_row <= s_fy ? s_row - {19'd0, s_w} : s_row + {19'd0, s_w};
					s_r <= s_r + 6'd1;
					if (s_r + 6'd1 == s_h[5:0] || s_h == 7'd64 && s_r == 6'd63) w_st <= W_FIN;
				end
			end
			W_GREQ: begin
				gfx_addr <= {f_a[26:3] + {21'd0, f_g}, 2'b00};
				gfx_req <= ~gfx_req;
				w_st <= W_GWAIT;
			end
			W_GWAIT: if (gfx_req == gfx_ack) begin
				rb[{sl_f, f_g}] <= gfx_dout;
				if (f_g == f_n) begin
					sl_full[sl_f] <= 1'b1;
					sl_f <= !sl_f;
					s_row <= s_fy ? s_row - {19'd0, s_w} : s_row + {19'd0, s_w};
					s_r <= s_r + 6'd1;
					w_st <= s_r + 6'd1 == s_h[5:0] || s_h == 7'd64 && s_r == 6'd63 ? W_FIN : W_ROW;
				end else begin
					f_g <= f_g + 3'd1;
					w_st <= W_GREQ;
				end
			end
			W_FIN: begin
				// the next entry, the next pass, or the end of the walk
				if (w_i != 10'd0) begin
					w_i <= w_i - 10'd1;
					w_st <= W_ENT;
				end else if (w_pass == 2'd1) begin
					w_pass <= 2'd2;
					w_i <= w_count;
					w_st <= W_ENT;
				end else begin
					draw_end <= 1'b1;
					w_st <= W_IDLE;
				end
			end
			default: ;
		endcase
		if (e_free_slot) sl_full[e_free_idx] <= 1'b0;
	end
end

// ---------------------------------------------------------------- the emitter
// pixel c of the slot being drawn each clock, packed four to a DDR3 word; a full queue holds it
reg         e_busy;
reg         e_slot;
reg  [6:0]  e_c;
reg         e_free_slot;            // a pulse: slot e_free_idx is drawn
reg         e_free_idx;
reg         pk_v;                   // a word is being packed
reg  [14:0] pk_a;
reg  [63:0] pk_d;
reg  [7:0]  pk_be;
wire [6:0]  e_sc  = sl_fx[e_slot] ? sl_w[e_slot] - 7'd1 - e_c : e_c;
wire [6:0]  e_bi  = {4'd0, sl_off[e_slot]} + (gfx4 ? {1'b0, e_sc[6:1]} : e_sc);
wire [63:0] e_g   = rb[{e_slot, e_bi[5:3]}];
wire [7:0]  e_byte = e_g[8 * e_bi[2:0] +: 8];
wire [7:0]  e_pen = gfx4 ? (e_sc[0] ? {4'd0, e_byte[7:4]} : {4'd0, e_byte[3:0]}) : e_byte;
wire [8:0]  e_sx  = sl_x[e_slot] + {2'd0, e_c};
wire        e_px  = e_busy && e_sx < 9'd384 && e_pen != 8'd0;
wire [14:0] e_wa  = {sl_y[e_slot][7:0], e_sx[8:2]};
wire        e_flush = pk_v && (e_px ? pk_a != e_wa : !e_busy && !sl_full[e_slot]);
wire        e_hold  = e_flush && !q_room;
assign q_buf = w_buf;

always @(posedge clk) begin
	q_we <= 1'b0;
	e_free_slot <= 1'b0;
	if (rst || restart) begin
		e_busy <= 1'b0;
		pk_v <= 1'b0;
		e_slot <= 1'b0;
		e_done <= 1'b1;
	end else begin
		e_done <= !e_busy && !sl_full[0] && !sl_full[1] && !pk_v;
		if (!e_hold) begin
			if (e_flush) begin
				q_we <= 1'b1; q_addr <= pk_a; q_data <= pk_d; q_be <= pk_be;
				pk_v <= 1'b0;
			end
			if (e_px) begin
				pk_v <= 1'b1;
				pk_a <= e_wa;
				pk_d[16 * e_sx[1:0] +: 16] <= {2'b00, sl_pri[e_slot], sl_col[e_slot], e_pen};
				pk_be <= (pk_v && pk_a == e_wa ? pk_be : 8'd0) | (8'b11 << {e_sx[1:0], 1'b0});
			end
			if (!e_busy) begin
				if (sl_full[e_slot]) begin e_busy <= 1'b1; e_c <= 7'd0; end
			end else begin
				e_c <= e_c + 7'd1;
				if (e_c + 7'd1 == sl_w[e_slot]) begin
					e_busy <= 1'b0;
					e_free_slot <= 1'b1;
					e_free_idx <= e_slot;
					e_slot <= !e_slot;
				end
			end
		end
	end
end

endmodule
