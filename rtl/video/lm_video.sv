// Limenko video (limenko.cpp, the SYS L2D_HYP chip): RAMs and registers as the CPU sees them, the raster, the
// vertical blank interrupt, three tilemaps, and the sprites (lm_sprites drawing into lm_fb, a DDR3 frame buffer).
//
// CPU windows (lm_main v0_* / v1_*: 32-bit words, registered reads, data one clock after the address):
//   v0 0x80000000-0x80007fff  fg VRAM 32 KB      0x80008000-0x8000ffff  md VRAM 32 KB
//   v1 0x80010000-0x80017fff  bg VRAM 32 KB      0x80018000-0x80019fff  sprite RAM 8 KB, two banks of 0x200
//                                                                       entries of 2 dwords
//      0x8001c000-0x8001dfff  palette 8 KB, 0x1000 xBGR555 entries, the even one in bits 31:16
//      0x8001e000-0x8001efff  RAM (MAME maps 0x8001e000-0x8001ebff, "not used")
//      0x8001ffec-0x8001ffff  video registers 0..4: [0] bits 3:0 enables (sprites, bg, md, fg), bits 25:16 the
//                             sprite count; [1] fg, [2] md, [3] bg scroll (x bits 31:16, y 15:0); [4] unused
//   Other addresses read 0.
// spr_cmd (a write to 0x8003e000, spriteram_buffer_w): spriteram_bit toggles, the bank it then selects is the one
// drawn, with the count latched at the previous command; the count is then latched from register 0. spriteram_bit
// starts at 1 (init_common, init_spotty).
//
// Raster: no raw timing in MAME (384 x 240 at 60 Hz). Here 8 MHz pixels (one in seven 56 MHz clocks) on aoh's
// 512 x 264 raster, 59.19 Hz: visible x 64..447, lines 0..239; the vertical blank, and the interrupt, from line 240
// (docs/HACKS.md).
//
// Tilemaps (get_*_tile_info, screen_update): 128 x 64 tiles of 8 x 8, 8bpp; entry bits 18:0 the tile (modulo the
// graphics' tile count), 31:28 the colour; palette entry colour * 256 + pen; bg opaque, md and fg skip pen 0; drawn
// bg, md, fg. Scroll and enables are latched at the interrupt, MAME's screen update; VRAM and the palette are read
// live (docs/HACKS.md). Each visible line is drawn up to three lines ahead of the one shown, into four line slots
// per layer, so a line slowed by the CPU's SDRAM traffic borrows from the next. Per enabled layer, 49 tiles from
// column scroll x / 8; each tile's 8-byte row is one SDRAM granule (gfx_*: sdram.sv port 0's toggle protocol, data
// on gfx_dout in the clock gfx_ack matches gfx_req); the next tile's VRAM read and fetch overlap the current tile's
// 8 pixel writes. spotty's graphics are 4bpp, the first pixel in bits 3:0 (init_spotty's expansion): a row is
// 4 bytes, half a granule.
//
// flip (the OSD's; the chip has no flip register) turns the 384 x 240 picture by 180 degrees, latched at the
// interrupt: shown line v is drawn from line 239 - v of the tilemaps and the sprite frame buffer, and both line
// buffers are read from x 383 down.

module lm_video #(
	parameter [26:0] GFX_BASE = 27'h0e00000,     // lm_sdram_map.svh LM_GFX
	parameter [28:0] FB_BASE  = 29'h6800000      // lm_fb: the frame buffer in DDR3, 64-bit words
) (
	input             clk,
	input             rst,
	input      [18:0] tile_count,       // the graphics' 64-byte tiles
	input             tile_pow2,        // tile_count is a power of two
	input             gfx4,             // spotty's 4bpp graphics
	input      [25:0] gfx_size,         // bytes of the graphics (the 8bpp space): the sprites' bounds check
	input             flip,

	// CPU side
	input             v0_we,
	input      [3:0]  v0_be,
	input      [13:0] v0_addr,
	input      [31:0] v0_wd,
	output reg [31:0] v0_rd,
	input             v1_we,
	input      [3:0]  v1_be,
	input      [13:0] v1_addr,
	input      [31:0] v1_wd,
	output reg [31:0] v1_rd,
	input             spr_cmd,
	output reg        spr_bit,
	output            v1_wait,          // the CPU's writes to v1 wait: the sprite list is being copied

	// graphics ROM (SDRAM port 0)
	output reg [26:1] gfx_addr,
	output reg        gfx_req = 1'b0,
	input             gfx_ack,
	input      [63:0] gfx_dout,

	// the sprite frame buffer
	output     [7:0]  DDRAM_BURSTCNT,
	output     [28:0] DDRAM_ADDR,
	output     [63:0] DDRAM_DIN,
	output     [7:0]  DDRAM_BE,
	output            DDRAM_WE,
	output            DDRAM_RD,
	input             DDRAM_BUSY,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,

	// video out
	output            ce_pix,
	output reg [7:0]  vid_r,
	output reg [7:0]  vid_g,
	output reg [7:0]  vid_b,
	output reg        hblank,
	output reg        vblank,
	output reg        hsync,
	output reg        vsync,
	output            frame_start,
	output            vblank_start,     // one clock at the start of line 240: the CPU's INT1

	output reg [15:0] dbg_overrun,      // lines whose tiles were not all drawn by the next line start
	output     [15:0] dbg_spr_late,     // interrupts at which a sprite draw was unfinished
	output reg [15:0] dbg_fb_late       // sprite lines not read from DDR3 by the next line start
);

// Timing
reg [2:0] pcnt;
reg [8:0] hcnt, vcnt;
wire p_last = pcnt == 3'd6;
assign ce_pix = pcnt == 3'd0;
wire line_start = pcnt == 3'd0 && hcnt == 9'd0;
assign frame_start = line_start && vcnt == 9'd0;
assign vblank_start = line_start && vcnt == 9'd240;

always @(posedge clk) begin
	if (rst) begin
		pcnt <= 3'd0; hcnt <= 9'd0; vcnt <= 9'd0;
	end else begin
		pcnt <= p_last ? 3'd0 : pcnt + 3'd1;
		if (p_last) begin
			if (hcnt == 9'd511) begin
				hcnt <= 9'd0;
				vcnt <= vcnt == 9'd263 ? 9'd0 : vcnt + 9'd1;
			end else hcnt <= hcnt + 9'd1;
		end
	end
end

wire x_active = hcnt >= 9'd64 && hcnt < 9'd448;
wire y_active = vcnt < 9'd240;

// RAMs and registers
wire w_md  = v0_addr[13];
wire w_bg  = !v1_addr[13];
wire w_spr = v1_addr[13:11] == 3'b100;
wire w_pal = v1_addr[13:11] == 3'b110;
wire w_ram = v1_addr[13:10] == 4'b1110;
wire w_reg = v1_addr[13:3] == 11'h7ff && v1_addr[2:0] >= 3'd3;

reg  [12:0] t_vaddr;                // the tile engine's VRAM address (row, column)
wire [10:0] sp_sr_addr;
wire [31:0] sp_sr_q;
reg  [10:0] pal_ra;
wire [31:0] fg_q, md_q, bg_q, spr_q, pal_q, ram_q, fg_tq, md_tq, bg_tq, pal_sq;
vh_ram_be #(.AW(13)) u_fg  (.clk(clk), .a_we(v0_we && !w_md), .a_be(v0_be), .a_addr(v0_addr[12:0]), .a_wd(v0_wd),
	.a_rd(fg_q), .b_addr(t_vaddr), .b_rd(fg_tq));
vh_ram_be #(.AW(13)) u_md  (.clk(clk), .a_we(v0_we && w_md), .a_be(v0_be), .a_addr(v0_addr[12:0]), .a_wd(v0_wd),
	.a_rd(md_q), .b_addr(t_vaddr), .b_rd(md_tq));
vh_ram_be #(.AW(13)) u_bg  (.clk(clk), .a_we(v1_we && w_bg), .a_be(v1_be), .a_addr(v1_addr[12:0]), .a_wd(v1_wd),
	.a_rd(bg_q), .b_addr(t_vaddr), .b_rd(bg_tq));
vh_ram_be #(.AW(11)) u_spr (.clk(clk), .a_we(v1_we && w_spr), .a_be(v1_be), .a_addr(v1_addr[10:0]), .a_wd(v1_wd),
	.a_rd(spr_q), .b_addr(sp_sr_addr), .b_rd(sp_sr_q));
vh_ram_be #(.AW(11)) u_pal (.clk(clk), .a_we(v1_we && w_pal), .a_be(v1_be), .a_addr(v1_addr[10:0]), .a_wd(v1_wd),
	.a_rd(pal_q), .b_addr(pal_ra), .b_rd(pal_sq));
vh_ram_be #(.AW(10)) u_ram (.clk(clk), .a_we(v1_we && w_ram), .a_be(v1_be), .a_addr(v1_addr[9:0]), .a_wd(v1_wd),
	.a_rd(ram_q), .b_addr(10'd0), .b_rd());

reg [31:0] vreg [0:4];
reg [9:0]  spr_count;               // latched at the previous command: the next draw's last entry
reg [3:0]  en_l;                    // register 0 bits 3:0 and the scroll registers, latched at the interrupt
reg [31:0] scr_l [1:3];
reg        flip_l;
integer    bi;
always @(posedge clk) begin
	if (rst) begin
		spr_bit <= 1'b1;
		spr_count <= 10'd0;
		en_l <= 4'd0;
		flip_l <= 1'b0;
	end else begin
		if (v1_we && w_reg)
			for (bi = 0; bi < 4; bi = bi + 1)
				if (v1_be[bi]) vreg[v1_addr[2:0] - 3'd3][8 * bi +: 8] <= v1_wd[8 * bi +: 8];
		if (spr_cmd) begin
			spr_bit <= !spr_bit;
			spr_count <= vreg[0][25:16];
		end
		if (vblank_start) begin
			en_l <= vreg[0][3:0];
			flip_l <= flip;
			scr_l[1] <= vreg[1]; scr_l[2] <= vreg[2]; scr_l[3] <= vreg[3];
		end
	end
end

// reads: the window's select a clock later, with the RAMs' data
reg       r_md;
reg [2:0] r_v1;                     // 0 bg, 1 sprite, 2 palette, 3 RAM, 4 register, 5 nothing
reg [2:0] r_reg;
always @(posedge clk) begin
	r_md  <= w_md;
	r_v1  <= w_bg ? 3'd0 : w_spr ? 3'd1 : w_pal ? 3'd2 : w_ram ? 3'd3 : w_reg ? 3'd4 : 3'd5;
	r_reg <= v1_addr[2:0] - 3'd3;
end
always @* begin
	v0_rd = r_md ? md_q : fg_q;
	case (r_v1)
		3'd0: v1_rd = bg_q;
		3'd1: v1_rd = spr_q;
		3'd2: v1_rd = pal_q;
		3'd3: v1_rd = ram_q;
		3'd4: v1_rd = vreg[r_reg];
		default: v1_rd = 32'd0;
	endcase
end

// Graphics port (SDRAM port 0): the sprite draw only while the tile engine is idle (between lines, up to three
// ahead), so a sprite row in flight never holds up a tile line. g_data is held for the one served.
reg  [26:1] t_addr;
wire        t_idle;                 // the tile engine has no line to draw
reg         t_req = 1'b0, t_ack = 1'b0, s_ack = 1'b0;
wire [26:1] s_addr;
wire        s_req;
reg  [63:0] g_data;
reg         g_busy, g_who;          // 0 tiles, 1 sprites
always @(posedge clk) begin
	if (rst) begin                  // the requesters reset their toggles to these acks
		g_busy <= 1'b0;
		gfx_req <= gfx_ack;
	end else if (!g_busy) begin
		if (t_req != t_ack) begin
			gfx_addr <= t_addr; gfx_req <= ~gfx_req; g_busy <= 1'b1; g_who <= 1'b0;
		end else if (s_req != s_ack && t_idle) begin
			gfx_addr <= s_addr; gfx_req <= ~gfx_req; g_busy <= 1'b1; g_who <= 1'b1;
		end
	end else if (gfx_req == gfx_ack) begin
		g_data <= gfx_dout;
		g_busy <= 1'b0;
		if (g_who) s_ack <= s_req; else t_ack <= t_req;
	end
end

// Sprites
wire        fb_qwe, fb_qclr, fb_qbuf, fb_room, fb_empty, fb_front, fb_shown;
wire [14:0] fb_qaddr;
wire [63:0] fb_qdata;
wire [7:0]  fb_qbe;
wire [15:0] sp_q;
wire        fb_late;
lm_sprites #(.GFX_BASE(GFX_BASE)) u_spr_draw (
	.clk(clk), .rst(rst), .gfx_size(gfx_size), .gfx4(gfx4),
	.cmd(spr_cmd), .cmd_bank(!spr_bit), .cmd_count(spr_count), .vbl(vblank_start),
	.front(fb_front), .shown(fb_shown),
	.sr_addr(sp_sr_addr), .sr_q(sp_sr_q), .v1_wait(v1_wait),
	.gfx_addr(s_addr), .gfx_req(s_req), .gfx_ack(s_ack), .gfx_dout(g_data),
	.q_we(fb_qwe), .q_clr(fb_qclr), .q_buf(fb_qbuf), .q_addr(fb_qaddr), .q_data(fb_qdata), .q_be(fb_qbe),
	.q_room(fb_room), .q_empty(fb_empty), .dbg_late(dbg_spr_late)
);
lm_fb #(.FB_BASE(FB_BASE)) u_fb (
	.clk(clk), .rst(rst),
	.q_we(fb_qwe), .q_clr(fb_qclr), .q_buf(fb_qbuf), .q_addr(fb_qaddr), .q_data(fb_qdata), .q_be(fb_qbe),
	.q_room(fb_room), .q_empty(fb_empty),
	// flipped, line 239 - v goes to half v[0] ^ 1
	.ln_go(t_go), .ln(flip_l ? 8'd239 - t_line[7:0] : t_line[7:0]), .front(fb_front),
	.sp_ra({lb_ra[9] ^ flip_l, lb_ra[8:0]}), .sp_q(sp_q), .dbg_late(fb_late),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY)
);
always @(posedge clk)
	if (rst) dbg_fb_late <= 16'd0;
	else if (fb_late) dbg_fb_late <= dbg_fb_late + 16'd1;

// Tile engine
// the next line; if visible, its sprite line is read
wire [8:0] t_line = vcnt == 9'd263 ? 9'd0 : vcnt + 9'd1;
wire       t_go   = line_start && t_line < 9'd240;
// the tile lines: r_next is drawn next, while it is at most three ahead of the line shown (lines 0-3 in the blank)
reg  [8:0] r_next;
wire       r_ok = r_next < 9'd240 && (vcnt >= 9'd240 ? r_next < 9'd4 : r_next <= vcnt + 9'd3);

// line buffers, one per layer: address {slot = line bits 1:0, x}, data {colour, pen}
reg         lb_we;
reg  [1:0]  lb_layer;
reg  [10:0] lb_wa;
reg  [11:0] lb_wd;
reg  [10:0] lb_ra;
wire [11:0] lb_bg, lb_md, lb_fg;
vh_sdp #(.AW(11), .DW(12)) u_lbg (.clk(clk), .we(lb_we && lb_layer == 2'd0), .wa(lb_wa), .wd(lb_wd), .ra(lb_ra), .rd(lb_bg));
vh_sdp #(.AW(11), .DW(12)) u_lmd (.clk(clk), .we(lb_we && lb_layer == 2'd1), .wa(lb_wa), .wd(lb_wd), .ra(lb_ra), .rd(lb_md));
vh_sdp #(.AW(11), .DW(12)) u_lfg (.clk(clk), .we(lb_we && lb_layer == 2'd2), .wa(lb_wa), .wd(lb_wd), .ra(lb_ra), .rd(lb_fg));

// fetch side: a tile's VRAM entry is read while the tile before it is fetched; its row is requested in the
// clock the tile before is handed to the write side. Rows arrive on gfx_dout and wait in f_data for the write side.
localparam [2:0] F_IDLE = 0, F_LAYER = 1, F_FIRST = 2, F_WAIT = 3, F_HAND = 4;
reg  [2:0]  f_st;
reg  [8:0]  f_line;
reg  [1:0]  f_layer;
reg  [5:0]  f_k;                    // the tile in flight, 0..48 of the line
reg  [31:0] f_scr;
reg  [3:0]  f_col;                  // its colour
reg  [63:0] f_data;
reg         f_half;                 // spotty: the row is the granule's upper 4 bytes
reg  [31:0] e_nxt;                  // the next tile's VRAM entry
reg         e_nxt_v;
reg  [1:0]  vr_pipe;                // a VRAM read in flight: its data is on *_tq when bit 1 is set
wire [8:0]  f_src = flip_l ? 9'd239 - f_line : f_line;   // the tilemap line drawn into slot f_line
wire [8:0]  f_ty = f_src + f_scr[8:0];
wire [31:0] f_tq = f_layer == 2'd0 ? bg_tq : f_layer == 2'd1 ? md_tq : fg_tq;
function [18:0] code_of(input [31:0] e);
	code_of = tile_pow2 ? e[18:0] & (tile_count - 19'd1) : (e[18:0] >= tile_count ? e[18:0] - tile_count : e[18:0]);
endfunction
// the row's byte address: tile * 64 + row * 8 (4bpp: half that)
function [26:0] byte_of(input [31:0] e);
	byte_of = GFX_BASE + (gfx4 ? {6'd0, code_of(e), f_ty[2:0], 2'b00} : {5'd0, code_of(e), f_ty[2:0], 3'b000});
endfunction
wire [26:0] n_byte = byte_of(e_nxt);
wire [8:0]  l_ty = f_src + scr_l[3 - f_layer][8:0];   // a layer's first row, before f_scr is loaded

// write side: pixel j of tile k at x = k * 8 + j - (scroll x & 7), written if in 0..383
reg         w_busy;
reg  [2:0]  w_j;
reg  [5:0]  w_k;
reg  [2:0]  w_fine;
reg  [1:0]  w_layer;
reg  [3:0]  w_col;
reg  [63:0] w_pix;                  // pixel j in bits 8j+7..8j
reg  [1:0]  w_slot;
wire [9:0]  w_p = {1'b0, w_k, w_j};         // k * 8 + j
wire [9:0]  w_x = w_p - {7'd0, w_fine};

function [63:0] expand4(input [31:0] b);    // 4bpp to 8bpp: byte i's low nibble first
	integer i;
	for (i = 0; i < 4; i = i + 1) begin
		expand4[16 * i +: 8]     = {4'd0, b[8 * i +: 4]};
		expand4[16 * i + 8 +: 8] = {4'd0, b[8 * i + 4 +: 4]};
	end
endfunction

reg        f_rs;                    // the interrupt restarts the lines from 0, once no row is in flight
wire       f_safe = f_st != F_WAIT;
assign     t_idle = f_st == F_IDLE && !r_ok;
always @(posedge clk) begin
	lb_we <= 1'b0;
	vr_pipe <= {vr_pipe[0], 1'b0};
	if (vr_pipe[1]) begin e_nxt <= f_tq; e_nxt_v <= 1'b1; end
	if (rst) begin
		f_st <= F_IDLE;
		f_rs <= 1'b0;
		r_next <= 9'd240;
		w_busy <= 1'b0;
		e_nxt_v <= 1'b0;
		vr_pipe <= 2'b00;
		dbg_overrun <= 16'd0;
		t_req <= t_ack;
	end else begin
		// write side
		if (w_busy) begin
			lb_we <= w_p >= {7'd0, w_fine} && w_x < 10'd384;
			lb_layer <= w_layer;
			lb_wa <= {w_slot, w_x[8:0]};
			lb_wd <= {w_col, w_pix[8 * w_j +: 8]};
			w_j <= w_j + 3'd1;
			if (w_j == 3'd7) w_busy <= 1'b0;
		end

		// a visible line shown before it is drawn; the drawing skips past it
		if (line_start && vcnt < 9'd240 && r_next <= vcnt && !vblank_start) begin
			dbg_overrun <= dbg_overrun + 16'd1;
			if (f_st == F_IDLE) r_next <= vcnt + 9'd1;
		end
		if (vblank_start) f_rs <= 1'b1;
		if (f_rs && f_safe) begin
			// the interrupt: lines from 0, with the scroll and enables it latched
			f_rs <= 1'b0;
			r_next <= 9'd0;
			e_nxt_v <= 1'b0;
			vr_pipe <= 2'b00;
			f_st <= F_IDLE;
		end else if (f_st == F_IDLE) begin
			if (r_ok && !w_busy) begin
				f_line <= r_next;
				f_layer <= 2'd0;
				f_st <= F_LAYER;
			end
		end else case (f_st)
			F_LAYER:                  // the next enabled layer from f_layer, in the order bg, md, fg; read tile 0
				if (f_layer == 2'd3) begin f_st <= F_IDLE; r_next <= f_line + 9'd1; end
				else if (!en_l[2 - f_layer]) f_layer <= f_layer + 2'd1;
				else begin
					f_scr <= scr_l[3 - f_layer];
					t_vaddr <= {l_ty[8:3], scr_l[3 - f_layer][25:19]};
					vr_pipe <= 2'b01;
					e_nxt_v <= 1'b0;
					f_k <= 6'd0;
					f_st <= F_FIRST;
				end
			F_FIRST: if (e_nxt_v) begin    // tile 0's row requested, tile 1's entry read
				e_nxt_v <= 1'b0;
				f_col <= e_nxt[31:28];
				f_half <= gfx4 && n_byte[2];
				t_addr <= {n_byte[26:3], 2'b00};
				t_req <= ~t_req;
				t_vaddr <= {f_ty[8:3], f_scr[25:19] + 7'd1};
				vr_pipe <= 2'b01;
				f_st <= F_WAIT;
			end
			F_WAIT: if (t_req == t_ack) begin
				f_data <= gfx4 ? expand4(f_half ? g_data[63:32] : g_data[31:0]) : g_data;
				f_st <= F_HAND;
			end
			F_HAND: if ((!w_busy || w_j == 3'd7) && (f_k == 6'd48 || e_nxt_v)) begin
				w_busy <= 1'b1;
				w_j <= 3'd0;
				w_k <= f_k;
				w_fine <= f_scr[18:16];
				w_layer <= f_layer;
				w_col <= f_col;
				w_pix <= f_data;
				w_slot <= f_line[1:0];
				if (f_k == 6'd48) begin
					f_layer <= f_layer + 2'd1;
					f_st <= F_LAYER;
				end else begin
					// the next tile's row, and the entry of the one after it
					e_nxt_v <= 1'b0;
					f_col <= e_nxt[31:28];
					f_half <= gfx4 && n_byte[2];
					t_addr <= {n_byte[26:3], 2'b00};
					t_req <= ~t_req;
					if (f_k != 6'd47) begin
						t_vaddr <= {f_ty[8:3], f_scr[25:19] + {1'b0, f_k} + 7'd2};
						vr_pipe <= 2'b01;
					end
					f_k <= f_k + 6'd1;
					f_st <= F_WAIT;
				end
			end
			default: ;
		endcase
	end
end

// Scan-out: line buffers, layer choice, palette, by pcnt
reg        s_act, s_fgop;
// a sprite pixel shows when register 0 bit 3 is set: priority 2, or 1 where fg is transparent (copy_sprites)
wire       s_spr = en_l[3] && fb_shown && (sp_q[13:12] == 2'd2 || sp_q[13:12] == 2'd1 && !(en_l[0] && lb_fg[7:0] != 8'd0));
reg [11:0] s_idx;
reg        s_half;
function [7:0] p5(input [4:0] v);
	p5 = {v, v[4:2]};
endfunction
always @(posedge clk) begin
	if (pcnt == 3'd0) lb_ra <= {vcnt[1:0], flip_l ? 9'd447 - hcnt : hcnt - 9'd64};
	if (pcnt == 3'd2) begin
		s_act <= x_active && y_active;
		s_fgop <= en_l[0] && lb_fg[7:0] != 8'd0;
		s_idx <= s_spr ? sp_q[11:0] :
		         en_l[0] && lb_fg[7:0] != 8'd0 ? lb_fg : en_l[1] && lb_md[7:0] != 8'd0 ? lb_md : en_l[2] ? lb_bg : 12'd0;
	end
	if (pcnt == 3'd3) begin
		pal_ra <= s_idx[11:1];
		s_half <= s_idx[0];
	end
	if (pcnt == 3'd5) begin
		if (s_act) begin
			vid_r <= p5(s_half ? pal_sq[4:0]   : pal_sq[20:16]);
			vid_g <= p5(s_half ? pal_sq[9:5]   : pal_sq[25:21]);
			vid_b <= p5(s_half ? pal_sq[14:10] : pal_sq[30:26]);
		end else begin
			vid_r <= 8'd0; vid_g <= 8'd0; vid_b <= 8'd0;
		end
		hblank <= !x_active;
		vblank <= !y_active;
		hsync <= hcnt >= 9'd464 && hcnt < 9'd500;
		vsync <= vcnt >= 9'd244 && vcnt < 9'd247;
	end
end

endmodule
