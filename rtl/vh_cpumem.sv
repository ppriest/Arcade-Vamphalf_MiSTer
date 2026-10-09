// The E1's memory system: address decode, the CPU's internal RAM, the caches in front of work RAM and
// program ROM (both in SDRAM), the video RAM ports, the I/O port, and the owner of sdram.sv's port 2.
//
// Program space (vamphalf.cpp common_map / common_32bit_map, e132xs.cpp iram_4k_map):
//   0x00000000-0x001fffff  work RAM, 2 MB     SDRAM WRAM_BASE, through the caches
//   0x40000000-0x4000ffff  sprite RAM         vh_video spr_*
//   0x40010000-0x4003ffff  sprite RAM         SDRAM SPRHI_BASE, through the caches: only the power-on
//                                             test uses it (write sweep)
//   0x80000000-0x8000ffff  palette            vh_video pal_*
//   0xc0000000-0xdfffffff  internal RAM, 4 KB mirrored
//   0xfff00000-0xffffffff  program ROM, 1 MB  SDRAM ROM_BASE, through the caches
//   0xffe00000-0xffefffff  program ROM's first MB on a 2 MB program (prg2: yorijori_32bit_map), SDRAM
//                          PRGLO_BASE, through the caches
//   anything else reads 0, writes are dropped (0xe000xxxx also pulses xflip_we)
//
// Caches: I 16 KB, D 4 KB, direct-mapped, 16-byte lines filled by one double read. Instruction fetches
// have their own port (if_*, 8 bytes) so fetch-ahead does not wait behind loads and stores. Stores to
// work RAM and the upper sprite RAM are written through: they update whichever cache holds the line and
// enter a four-entry write buffer (wq_*), each entry written as one burst. A miss waits for the buffer
// to drain.
// After every D-cache fill the next line is read into a 16-byte prefetch buffer when port 2 is idle; a D
// miss on that line fills from it in two clocks. A store to the buffered line, or to the line in flight,
// discards it. Port 2 serves the write buffer first, so the prefetch never holds data older than a store.
//
// CPU bus timing (e1_cpu: req held until ack): I/O and internal/video RAM ack from a register, one clock
// after the request; a cache hit (S_LOOK), a store (S_WLOOK) and a data fill (S_FILL2) ack
// combinationally, so a hit costs two clocks, not three.
// Instruction port: if_addr is looked up in every clock in which the data side, a fill or the sweep does
// not hold the RAM it needs (i_free); if_ack comes in the clock after a lookup of the address still
// requested, so a lookup of an address the CPU has since changed is dropped. An I-cache miss is filled by
// the data side's miss logic when that has no request. Fetches outside work RAM, program ROM, the upper
// sprite RAM and the internal RAM read 0 (no game executes from anywhere else).
// A store updates the I-cache in S_WLOOK, the clock it is acked in; the CPU drops any fetched 8 bytes the
// store hits, and every later lookup reads the new data.
//
// SDRAM port 2 (sdram.sv's toggle protocol, burst writes), in priority order: download writes (dl_*), the
// write buffer, line fills, the prefetch. It is reset only by prst (the PLL's lock), never by the core
// reset: MiSTer holds the core reset for the whole download (LESSONS_LEARNED, "Never hold the memory path
// in the core reset").
// SDRAM words hold the even byte in [7:0]; the CPU is big-endian, so data is byte-swapped at this seam.

module vh_cpumem #(
	parameter [26:0] ROM_BASE  = 27'h0000000,
	parameter [26:0] WRAM_BASE = 27'h1800000,
	parameter [26:0] SPRHI_BASE = 27'h1a00000,
	parameter [26:0] PRGLO_BASE = 27'h0700000
) (
	input             clk,
	input             prst,            // power-up only: the port-2 side
	input             rst,
	input             prg2,            // a 2 MB program: ROM from 0xffe00000

	// CPU
	input             bus_req,
	input             bus_wr,
	input             bus_io,
	input      [31:0] bus_addr,
	input      [3:0]  bus_be,
	input      [31:0] bus_wdata,
	output            bus_ack,
	output     [31:0] bus_rdata,

	// CPU instruction port: 8 bytes, byte 0 in [63:56]
	input             if_req,
	input      [31:3] if_addr,
	output            if_ack,
	output     [63:0] if_data,

	// video RAMs (vh_video): registered reads, data one clock after the address
	output            spr_we,
	output     [3:0]  spr_be,
	output     [13:0] spr_addr,
	output     [31:0] spr_wd,
	input      [31:0] spr_rd,
	output            pal_we,
	output     [3:0]  pal_be,
	output     [13:0] pal_addr,
	output     [31:0] pal_wd,
	input      [31:0] pal_rd,

	// I/O: one-clock pulses; io_rdata is sampled in the clock of io_rd
	output            io_rd,
	output            io_wr,
	output     [18:0] io_port,         // bus_addr >> 13
	output     [31:0] io_wd,
	input      [31:0] io_rdata,
	input             io_late,         // this read's io_rdata is valid a clock after io_rd (a block RAM)

	// ROM download writes (sdram_download), or with dl_g a whole 8-byte granule at dl_addr (the fast load's
	// copy, vh_rom_loader), byte i of dl_gdata at dl_addr + i
	input             dl_req,
	input      [26:0] dl_addr,
	input      [15:0] dl_data,
	input             dl_we16,
	input             dl_g,
	input      [63:0] dl_gdata,
	output reg        dl_busy = 1'b0,

	// sdram.sv port 2
	output reg [26:1] mem_addr,
	output reg        mem_wrl,
	output reg        mem_wrh,
	output reg [15:0] mem_din,
	output reg [47:0] mem_dinx,        // words 1-3 of a burst write, and their byte enables
	output reg  [5:0] mem_wrx,
	output reg        mem_dbl,
	output reg        mem_req = 1'b0,
	input             mem_ack,
	input      [63:0] mem_dout,
	input      [63:0] mem_doutb,

	output reg [31:0] st_imiss = 0,    // counters for the benches
	output reg [31:0] st_dmiss = 0,
	output reg [26:1] dbg_fill_a,      // the first line fill after reset: its SDRAM address
	output reg [63:0] dbg_fill_d,      // and its second granule
	output            dbg_miss,        // one clock per cache miss: dbg_miss_ic, the line in the cached space
	output            dbg_miss_ic,
	output     [22:4] dbg_miss_line,
	output            xflip_we         // a write to 0xe000xxxx (jmpbreak_flipscreen_w): bus_wdata, bus_be
);

// ---------------------------------------------------------------- decode
wire r_wram = bus_addr[31:21] == 11'd0;
wire r_rom  = bus_addr[31:20] == 12'hfff;
wire r_rom2 = prg2 && bus_addr[31:20] == 12'hffe;
wire r_iram = bus_addr[31:29] == 3'b110;
wire r_spr  = bus_addr[31:16] == 16'h4000;
wire r_sprh = bus_addr[31:18] == 14'h1000 && bus_addr[17:16] != 2'd0;
wire r_pal  = bus_addr[31:16] == 16'h8000;
wire r_sd   = r_wram || r_rom || r_rom2 || r_sprh;  // through the caches
wire [22:0] caddr = r_wram ? {2'b00, bus_addr[20:0]} : r_rom ? {3'b010, bus_addr[19:0]} :
                    r_rom2 ? {3'b011, bus_addr[19:0]} : {5'b10000, bus_addr[17:0]};

wire [31:0] ifa    = {if_addr, 3'b000};
wire        i_wram = ifa[31:21] == 11'd0;
wire        i_rom  = ifa[31:20] == 12'hfff;
wire        i_rom2 = prg2 && ifa[31:20] == 12'hffe;
wire        i_iram = ifa[31:29] == 3'b110;
wire        i_sprh = ifa[31:18] == 14'h1000 && ifa[17:16] != 2'd0;
wire        i_sd   = i_wram || i_rom || i_rom2 || i_sprh;
wire [22:0] i_caddr = i_wram ? {2'b00, ifa[20:0]} : i_rom ? {3'b010, ifa[19:0]} :
                      i_rom2 ? {3'b011, ifa[19:0]} : {5'b10000, ifa[17:0]};

// the cached space: 0x000000 work RAM, 0x200000 program ROM, 0x300000 its first MB on a 2 MB program,
// 0x400000 sprite RAM above 64 KB
function [26:0] sdram_of(input [22:0] ca);
	sdram_of = ca[22] ? SPRHI_BASE + {9'd0, ca[17:0]} : !ca[21] ? WRAM_BASE + {6'd0, ca[20:0]} :
	           !ca[20] ? ROM_BASE + {7'd0, ca[19:0]} : PRGLO_BASE + {7'd0, ca[19:0]};
endfunction

// SDRAM granule (4 little-endian-lane words, lowest address in [15:0]) -> 8 bytes, byte 0 in [63:56]
function [63:0] sw64(input [63:0] g);
	sw64 = {g[7:0], g[15:8], g[23:16], g[31:24], g[39:32], g[47:40], g[55:48], g[63:56]};
endfunction

// ---------------------------------------------------------------- state
localparam [3:0] S_INIT = 0, S_IDLE = 1, S_LOOK = 2, S_WLOOK = 3, S_MISS = 4, S_FILL = 5,
                 S_FILL2 = 6, S_ACK = 7, S_IOW = 8;
localparam [1:0] SRC_REG = 0, SRC_IRAM = 1, SRC_SPR = 2, SRC_PAL = 3;

reg  [3:0]  st;
reg  [10:0] swc;
reg         ack_r;
reg  [1:0]  rsrc;
reg  [31:0] rdata_r;
reg  [22:0] fa;
reg         f_ic;               // the fill is for the I-cache
reg  [63:0] lg0, lg1;           // the line, swapped
reg         line_req, line_done;
reg         dbg_filled = 1'b0;

// D-side next-line prefetch
reg         pf_want, pf_valid, pf_kill, pf_use;
reg  [22:4] pf_want_line, pf_fl_line, pf_line;
reg  [63:0] pf0, pf1;

// write buffer: four 8-byte blocks (byte 0 in [63:56], be[7] its enable), drained in order
(* ramstyle = "logic" *) reg  [22:3] wq_ca [0:3];   // registers: read combinationally; as RAM, reading an entry written in the same clock would depend on bypass logic Quartus may not add
(* ramstyle = "logic" *) reg  [7:0]  wq_be [0:3];
(* ramstyle = "logic" *) reg  [63:0] wq_d  [0:3];
reg  [2:0]  wq_w = 3'd0, wq_r = 3'd0;
wire        wb_valid = wq_w != wq_r;
wire        wb_full  = (wq_w - wq_r) == 3'd4;
wire [22:3] wb_ca = wq_ca[wq_r[1:0]];
wire [7:0]  wb_be = wq_be[wq_r[1:0]];
wire [63:0] wb_d  = wq_d[wq_r[1:0]];
wire [1:0]  wq_t  = wq_w[1:0] - 2'd1;       // the newest entry

wire idle_go = st == S_IDLE && bus_req;

// ---------------------------------------------------------------- caches
wire        ic_hit, dc_hit;
wire [63:0] ic_q, dc_q;
wire        sweep = st == S_INIT;
wire [7:0]  st_be8 = bus_addr[2] ? {4'b0, bus_be} : {bus_be, 4'b0};
wire        fill_we = st == S_FILL && (line_done || pf_use) || st == S_FILL2;
wire        fill_half = st == S_FILL2;
wire [63:0] fill_d = st == S_FILL2 ? lg1 : lg0;

// the data side has the I-cache's port for a store: the lookup in the request clock, the update in WLOOK
wire        ic_by_d = (idle_go && bus_wr && !bus_io && (r_wram || r_sprh)) || st == S_WLOOK;
vh_cache #(.AW(23), .LW(10)) u_ic (.clk(clk), .sweep(sweep), .sw_idx(swc[9:0]),
	.la(ic_by_d ? caddr : i_caddr), .hit(ic_hit), .q(ic_q),
	.fill_we(fill_we && f_ic), .fill_tag(fill_half), .fa(fa), .fill_half(fill_half), .fill_d(fill_d),
	.st_we(st == S_WLOOK && ic_hit), .st_be(st_be8), .st_d({bus_wdata, bus_wdata}));
vh_cache #(.AW(23), .LW(8)) u_dc (.clk(clk), .sweep(sweep), .sw_idx(swc[7:0]),
	.la(caddr), .hit(dc_hit), .q(dc_q),
	.fill_we(fill_we && !f_ic), .fill_tag(fill_half), .fa(fa), .fill_half(fill_half), .fill_d(fill_d),
	.st_we(st == S_WLOOK && dc_hit), .st_be(st_be8), .st_d({bus_wdata, bus_wdata}));

// ---------------------------------------------------------------- internal RAM
// 8 bytes wide for the instruction port; the data side has it in its request clock
wire [63:0] iram_q;
wire        ir_by_d = idle_go && !bus_io && r_iram;
vh_cache_ram #(.AW(9), .DW(64), .NB(8)) u_iram (.clk(clk), .addr(ir_by_d ? bus_addr[11:3] : if_addr[11:3]),
	.we(ir_by_d && bus_wr), .be(st_be8), .wd({bus_wdata, bus_wdata}), .q(iram_q));

// ---------------------------------------------------------------- instruction port
wire        i_free = i_sd ? !(sweep || (fill_we && f_ic) || ic_by_d) : i_iram ? !ir_by_d : 1'b1;
reg         i_look = 1'b0;      // if_addr was looked up in the previous clock, as i_la
reg  [31:3] i_la;
reg         i_sd_r, i_iram_r;
reg  [22:0] i_ca_r;
always @(posedge clk) begin
	i_look <= if_req && i_free;
	i_la <= if_addr; i_sd_r <= i_sd; i_iram_r <= i_iram; i_ca_r <= i_caddr;
end
wire        i_cur  = i_look && if_req && i_la == if_addr;
wire        i_miss = i_cur && i_sd_r && !ic_hit;
wire        i_take = st == S_IDLE && !bus_req && i_miss;    // the miss logic fills it
assign if_ack  = i_cur && (!i_sd_r || ic_hit);
assign if_data = i_iram_r ? iram_q : i_sd_r ? ic_q : 64'd0;

// ---------------------------------------------------------------- video RAMs, I/O
assign spr_we   = idle_go && bus_wr && !bus_io && r_spr;
assign xflip_we = idle_go && bus_wr && !bus_io && bus_addr[31:16] == 16'he000;
assign spr_be   = bus_be;
assign spr_addr = bus_addr[15:2];
assign spr_wd   = bus_wdata;
assign pal_we   = idle_go && bus_wr && !bus_io && r_pal;
assign pal_be   = bus_be;
assign pal_addr = bus_addr[15:2];
assign pal_wd   = bus_wdata;
assign io_rd    = idle_go && bus_io && !bus_wr;
assign io_wr    = idle_go && bus_io && bus_wr;
assign io_port  = bus_addr[31:13];
assign io_wd    = bus_wdata;

wire        look_hit = st == S_LOOK && dc_hit;
assign dbg_miss      = (st == S_LOOK && !look_hit) || i_take;
assign dbg_miss_ic   = i_take;
assign dbg_miss_line = i_take ? i_ca_r[22:4] : caddr[22:4];
assign bus_ack   = ack_r || look_hit || st == S_WLOOK || (st == S_FILL2 && !f_ic);
assign bus_rdata = st == S_LOOK ? (bus_addr[2] ? dc_q[31:0] : dc_q[63:32]) :
                   rsrc == SRC_IRAM ? (bus_addr[2] ? iram_q[31:0] : iram_q[63:32]) :
                   rsrc == SRC_SPR ? spr_rd : rsrc == SRC_PAL ? pal_rd : rdata_r;

// ---------------------------------------------------------------- CPU side and port 2
reg  [2:0]  m_who;              // what port 2 is doing
localparam [2:0] W_NONE = 0, W_DL = 1, W_WB = 2, W_LINE = 4, W_PF = 5;
wire        m_free = m_who == W_NONE;
wire [26:0] wb_sa = sdram_of({wb_ca, 3'd0});
// a store merges into the newest entry if that holds its block and is not being written, or about to be
// (port 2 takes the head in any clock it is free and no download write waits)
wire        wb_head_out = m_who == W_WB || (m_free && !dl_req);
wire        wb_merge = wb_valid && wq_ca[wq_t] == caddr[22:3] && !(wq_t == wq_r[1:0] && wb_head_out);
wire [26:0] fa_sa = sdram_of(fa);
wire [26:0] pf_sa = sdram_of({pf_want_line, 4'd0});
wire        pf_match = pf_valid && pf_line == caddr[22:4];

integer bi;
always @(posedge clk) begin
	line_done <= 1'b0;

	// port 2: one access at a time
	if (prst) begin
		m_who <= W_NONE;
		line_req <= 1'b0;
		dl_busy <= 1'b0;
		wq_w <= 3'd0; wq_r <= 3'd0;
		mem_req <= mem_ack;            // nothing outstanding
	end else if (m_free) begin
		if (dl_req) begin
			mem_addr <= dl_g ? {dl_addr[26:3], 2'd0} : dl_addr[26:1];
			mem_wrl  <= dl_g || dl_we16 || !dl_addr[0];
			mem_wrh  <= dl_g || dl_we16 ||  dl_addr[0];
			mem_din  <= dl_g ? dl_gdata[15:0] : dl_we16 ? dl_data : {dl_data[7:0], dl_data[7:0]};
			mem_dinx <= dl_gdata[63:16];
			mem_wrx  <= dl_g ? 6'h3f : 6'd0;
			mem_dbl  <= 1'b0;
			mem_req  <= ~mem_req;
			dl_busy  <= 1'b1;
			m_who    <= W_DL;
		end else if (wb_valid) begin
			// SDRAM word k of the block: byte 2k in [7:0], byte 2k+1 in [15:8]
			mem_addr <= {wb_sa[26:3], 2'd0};
			mem_wrl  <= wb_be[7];
			mem_wrh  <= wb_be[6];
			mem_din  <= {wb_d[55:48], wb_d[63:56]};
			mem_dinx <= {wb_d[7:0], wb_d[15:8], wb_d[23:16], wb_d[31:24], wb_d[39:32], wb_d[47:40]};
			mem_wrx  <= {wb_be[0], wb_be[1], wb_be[2], wb_be[3], wb_be[4], wb_be[5]};
			mem_dbl  <= 1'b0;
			mem_req  <= ~mem_req;
			m_who    <= W_WB;
		end else if (line_req) begin
			mem_addr <= {fa_sa[26:4], 3'd0};
			mem_wrl  <= 1'b0;
			mem_wrh  <= 1'b0;
			mem_wrx  <= 6'd0;
			mem_dbl  <= 1'b1;
			mem_req  <= ~mem_req;
			line_req <= 1'b0;
			m_who    <= W_LINE;
		end else if (pf_want) begin
			mem_addr <= {pf_sa[26:4], 3'd0};
			mem_wrl  <= 1'b0;
			mem_wrh  <= 1'b0;
			mem_wrx  <= 6'd0;
			mem_dbl  <= 1'b1;
			mem_req  <= ~mem_req;
			pf_want  <= 1'b0;
			pf_fl_line <= pf_want_line;
			pf_kill  <= 1'b0;
			m_who    <= W_PF;
		end
	end else if (mem_ack == mem_req) begin
		case (m_who)
			W_DL:   dl_busy <= 1'b0;
			W_WB:   wq_r <= wq_r + 3'd1;
			W_LINE: begin
				lg0 <= sw64(mem_dout); lg1 <= sw64(mem_doutb); line_done <= 1'b1;
				if (!dbg_filled) begin dbg_filled <= 1'b1; dbg_fill_a <= mem_addr; dbg_fill_d <= sw64(mem_doutb); end
			end
			W_PF:   if (!pf_kill) begin
				pf0 <= sw64(mem_dout); pf1 <= sw64(mem_doutb); pf_line <= pf_fl_line; pf_valid <= 1'b1;
			end
			default: ;
		endcase
		m_who <= W_NONE;
	end

	// CPU side
	ack_r <= 1'b0;
	if (rst) begin
		st  <= S_INIT;
		swc <= 11'd0;
		rsrc <= SRC_REG;
		pf_valid <= 1'b0;
		pf_want <= 1'b0;
		pf_use <= 1'b0;
		pf_kill <= 1'b1;               // a read in flight across the reset is dropped
		dbg_filled <= 1'b0;
	end else case (st)
		S_INIT: begin
			swc <= swc + 11'd1;
			if (swc[10]) st <= S_IDLE;
		end
		S_IDLE: if (bus_req) begin
			rsrc <= SRC_REG;
			if (bus_io && io_late && !bus_wr) begin
				st <= S_IOW;
			end else if (bus_io) begin
				rdata_r <= io_rdata;
				ack_r <= 1'b1; st <= S_ACK;
			end else if (r_iram || r_spr || r_pal) begin
				rsrc <= bus_wr ? SRC_REG : r_iram ? SRC_IRAM : r_spr ? SRC_SPR : SRC_PAL;
				ack_r <= 1'b1; st <= S_ACK;
			end else if (r_sd && !bus_wr) begin
				st <= S_LOOK;
			end else if ((r_wram || r_sprh) && bus_wr) begin
				if (wb_merge || !wb_full) begin
					if (pf_match) pf_valid <= 1'b0;
					if (m_who == W_PF && pf_fl_line == caddr[22:4]) pf_kill <= 1'b1;
					if (pf_want && pf_want_line == caddr[22:4]) pf_kill <= 1'b1;   // issued in this clock
					if (wb_merge) begin
						wq_be[wq_t] <= wq_be[wq_t] | st_be8;
						for (bi = 0; bi < 8; bi = bi + 1)
							if (st_be8[bi]) wq_d[wq_t][8*bi +: 8] <= bus_wdata[8*(bi & 3) +: 8];
					end else begin
						wq_ca[wq_w[1:0]] <= caddr[22:3];
						wq_be[wq_w[1:0]] <= st_be8;
						wq_d[wq_w[1:0]]  <= {bus_wdata, bus_wdata};
						wq_w <= wq_w + 3'd1;
					end
					st <= S_WLOOK;
				end
			end else begin
				rdata_r <= 32'd0;
				ack_r <= 1'b1; st <= S_ACK;
			end
		end else if (i_miss) begin            // i_take
			fa <= i_ca_r;
			f_ic <= 1'b1;
			st_imiss <= st_imiss + 1'd1;
			st <= S_MISS;
		end
		S_LOOK: begin
			if (look_hit) begin
				st <= S_IDLE;                 // acked in this clock
			end else begin
				fa <= caddr;
				f_ic <= 1'b0;
				st_dmiss <= st_dmiss + 1'd1;
				if (pf_match) begin
					lg0 <= pf0; lg1 <= pf1;
					pf_use <= 1'b1;
					pf_valid <= 1'b0;
					st <= S_FILL;
				end else st <= S_MISS;
			end
		end
		S_WLOOK: begin                    // the caches update on a hit in this clock; acked in it
			st <= S_IDLE;
		end
		S_MISS: if (!wb_valid) begin
			line_req <= 1'b1;
			st <= S_FILL;
		end
		S_FILL: if (line_done || pf_use) begin
			rdata_r <= fa[3] ? (fa[2] ? lg1[31:0] : lg1[63:32]) : (fa[2] ? lg0[31:0] : lg0[63:32]);
			pf_use <= 1'b0;
			if (!f_ic) begin              // the next line, behind anything else on port 2
				pf_want <= 1'b1;
				pf_want_line <= fa[22:4] + 19'd1;
			end
			st <= S_FILL2;
		end
		S_FILL2: begin                    // a data fill is acked in this clock, with rdata_r
			rsrc <= SRC_REG;
			st <= S_IDLE;
		end
		S_ACK: st <= S_IDLE;
		S_IOW: begin
			rdata_r <= io_rdata;
			ack_r <= 1'b1; st <= S_ACK;
		end
		default: st <= S_IDLE;
	endcase
end

endmodule
