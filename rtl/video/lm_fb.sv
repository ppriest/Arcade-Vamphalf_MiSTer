// The Limenko sprite frame buffer in DDR3 (ROADMAP Phase 8, memory plan): two buffers of 240 lines, each line 512
// pixels of 16 bits (the visible 384 used): bits 11:0 the palette index, 13:12 the priority (0 none, 1 below fg,
// 2 above all). The draw side (lm_sprites) queues pixel words and clears; the scan-out reads the front buffer's
// next line into a line buffer during the line before.
//
//   buffer b, line l, word k (4 pixels, pixel x in bits 16 * (x & 3) + 15..): DDR3 64-bit word
//   FB_BASE + b * 0x8000 + l * 128 + k
//
// DDRAM_* is MiSTer's Avalon port: a read of BURSTCNT words returns them on DOUT_READY beats; a burst write holds
// WE for each beat, ADDR and BURSTCNT taken on the first; BUSY stalls either. One transaction at a time here. A
// line read goes before queued writes; a clear is queued with the writes, so it lands after the writes before it.

module lm_fb #(
	parameter [28:0] FB_BASE = 29'h6800000    // 64-bit words: byte 0x34000000
) (
	input             clk,
	input             rst,

	// the draw side: one 64-bit word of 4 pixels (byte enables), or a clear of a whole buffer
	input             q_we,
	input             q_clr,
	input             q_buf,
	input      [14:0] q_addr,           // line * 128 + word
	input      [63:0] q_data,
	input      [7:0]  q_be,
	output            q_room,           // at least 8 free entries
	output            q_empty,          // nothing queued or being written

	// scan-out: at ln_go, line ln of buffer front is read into line buffer half ln[0]
	input             ln_go,
	input      [7:0]  ln,
	input             front,
	input      [9:0]  sp_ra,            // {half, x}
	output reg [15:0] sp_q,             // a clock after sp_ra
	output reg        dbg_late,         // a line read was still running at the next ln_go

	output     [7:0]  DDRAM_BURSTCNT,
	output     [28:0] DDRAM_ADDR,
	output     [63:0] DDRAM_DIN,
	output     [7:0]  DDRAM_BE,
	output            DDRAM_WE,
	output            DDRAM_RD,
	input             DDRAM_BUSY,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY
);

// queue: {clr, buf, addr, be, data}
localparam QW = 1 + 1 + 15 + 8 + 64;
reg  [QW-1:0] qm [0:511];
reg  [9:0]    qw_p = 10'd0, qr_p = 10'd0;
reg  [QW-1:0] qh;                   // the head, read a clock after qr_p moves
wire [9:0]    q_used = qw_p - qr_p;
assign q_room = q_used < 10'd504;
always @(posedge clk) begin
	if (q_we || q_clr) qm[qw_p[8:0]] <= {q_clr, q_buf, q_addr, q_be, q_data};
	qh <= qm[qr_p[8:0]];
end

// line buffer: two halves of 128 words
reg         lb_we;
reg  [7:0]  lb_wa;
reg  [63:0] lb_wd;
reg  [63:0] lbm [0:255];
reg  [63:0] lb_q;
reg  [1:0]  sp_lane;
always @(posedge clk) begin
	if (lb_we) lbm[lb_wa] <= lb_wd;
	lb_q <= lbm[{sp_ra[9], sp_ra[8:2]}];
	sp_lane <= sp_ra[1:0];
end
always @* sp_q = lb_q[16 * sp_lane +: 16];

localparam [2:0] S_IDLE = 0, S_HEAD = 1, S_RD = 2, S_RDW = 3, S_WR = 4, S_CLR = 5;
reg  [2:0]  st;
reg         rd_want;
reg  [7:0]  rd_ln;
reg         rd_buf;
reg  [6:0]  beat;
reg  [7:0]  cl_line;
reg         cl_active;              // a clear has started (and resumes after a line read)
reg  [6:0]  cl_beat;
reg         a_rd, a_we;
reg  [28:0] a_addr;
reg  [7:0]  a_cnt, a_be;
reg  [63:0] a_din;

assign DDRAM_RD       = a_rd;
assign DDRAM_WE       = a_we;
assign DDRAM_ADDR     = a_addr;
assign DDRAM_BURSTCNT = a_cnt;
assign DDRAM_BE       = a_be;
assign DDRAM_DIN      = a_din;
assign q_empty = q_used == 10'd0 && st != S_WR && st != S_CLR;

wire        h_clr  = qh[QW-1];
wire        h_buf  = qh[QW-2];
wire [14:0] h_addr = qh[QW-3 -: 15];
wire [7:0]  h_be   = qh[71:64];
wire [63:0] h_data = qh[63:0];

always @(posedge clk) begin
	lb_we <= 1'b0;
	dbg_late <= 1'b0;
	if (ln_go) begin
		if (rd_want || st == S_RD || st == S_RDW) dbg_late <= 1'b1;
		rd_want <= 1'b1;
		rd_ln <= ln;
		rd_buf <= front;
	end
	if (rst) begin
		st <= S_IDLE;
		rd_want <= 1'b0;
		a_rd <= 1'b0; a_we <= 1'b0;
		cl_active <= 1'b0;
		qr_p <= 10'd0; qw_p <= 10'd0;
	end else begin
		if (q_we || q_clr) qw_p <= qw_p + 10'd1;
		case (st)
			S_IDLE:
				if (rd_want) begin
					a_rd <= 1'b1;
					a_addr <= FB_BASE + {13'd0, rd_buf, 15'd0} + {14'd0, rd_ln, 7'd0};
					a_cnt <= 8'd96;
					a_be <= 8'hff;
					rd_want <= 1'b0;
					beat <= 7'd0;
					st <= S_RD;
				end else if (q_used != 10'd0) st <= S_HEAD;   // qh holds the head from the next clock
			S_HEAD:
				if (h_clr) begin
					if (!cl_active) begin cl_line <= 8'd0; cl_active <= 1'b1; end
					st <= S_CLR;
				end else begin
					a_we <= 1'b1;
					a_addr <= FB_BASE + {13'd0, h_buf, 15'd0} + {14'd0, h_addr};
					a_cnt <= 8'd1;
					a_be <= h_be;
					a_din <= h_data;
					st <= S_WR;
				end
			S_RD: if (!DDRAM_BUSY) begin a_rd <= 1'b0; st <= S_RDW; end
			S_WR: if (!DDRAM_BUSY) begin
				a_we <= 1'b0;
				qr_p <= qr_p + 10'd1;
				st <= S_IDLE;
			end
			S_CLR: begin
				// line cl_line's 96 words, one burst; between lines a waiting line read goes first
				if (!a_we) begin
					if (cl_line == 8'd240) begin
						qr_p <= qr_p + 10'd1;
						cl_active <= 1'b0;
						st <= S_IDLE;
					end else if (rd_want) st <= S_IDLE;
					else begin
						a_we <= 1'b1;
						a_addr <= FB_BASE + {13'd0, h_buf, 15'd0} + {14'd0, cl_line, 7'd0};
						a_cnt <= 8'd96;
						a_be <= 8'hff;
						a_din <= 64'd0;
						cl_beat <= 7'd0;
					end
				end else if (!DDRAM_BUSY) begin
					if (cl_beat == 7'd95) begin
						a_we <= 1'b0;
						cl_line <= cl_line + 8'd1;
					end
					cl_beat <= cl_beat + 7'd1;
				end
			end
			default: ;
		endcase
		if (st == S_RDW && DDRAM_DOUT_READY) begin
			lb_we <= 1'b1;
			lb_wa <= {rd_ln[0], beat};
			lb_wd <= DDRAM_DOUT;
			beat <= beat + 7'd1;
			if (beat == 7'd95) st <= S_IDLE;
		end
	end
end

endmodule
