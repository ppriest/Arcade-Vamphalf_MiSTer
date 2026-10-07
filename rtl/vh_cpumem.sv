// The E1's memory system: address decode, the CPU's internal RAM, the caches in front of work RAM and
// program ROM (both in SDRAM), the video RAM ports, the I/O port, and the owner of sdram.sv's port 2.
//
// Program space (vamphalf.cpp common_map / common_32bit_map, e132xs.cpp iram_4k_map):
//   0x00000000-0x001fffff  work RAM, 2 MB     SDRAM WRAM_BASE, through the caches
//   0x40000000-0x4000ffff  sprite RAM         vh_video spr_*
//   0x40010000-0x4003ffff  sprite RAM         SDRAM SPRHI_BASE, through the caches: the power-on test
//                                             walks it, nothing else uses it (write sweep)
//   0x80000000-0x8000ffff  palette            vh_video pal_*
//   0xc0000000-0xdfffffff  internal RAM, 4 KB mirrored
//   0xfff00000-0xffffffff  program ROM, 1 MB  SDRAM ROM_BASE, through the caches
//   anything else reads 0, writes are dropped
//
// Instruction fetches of SDRAM regions go through the I-cache (16 KB), data reads through the D-cache
// (4 KB); both are direct-mapped with 16-byte lines filled by one double read. Stores to work RAM are
// written through: they update whichever cache holds the line and go to a four-entry write buffer, so
// the CPU continues while the SDRAM writes run. A miss waits for the buffer to drain.
// Data reads stream: after every D-cache fill the next line is read into a 16-byte prefetch buffer when
// port 2 has nothing else to do, and a D miss on that line fills from the buffer in two clocks. A store
// to the buffered line, or to the line in flight, discards it. The buffer is read only after the write
// buffer has drained (port 2 serves the write buffer first), so it never holds data older than a store.
//
// CPU bus timing (e1_cpu: req held until ack): every access is acked one clock after the request is
// seen at the earliest. I/O and internal/video RAM ack from a register; a cache hit, a store and the
// end of a line fill ack combinationally in the clock after the request (the hit compare drives
// bus_ack), so a hit costs two clocks, not three. An instruction fetch from the 8-byte half the last
// cached fetch read is acked in the clock it is requested (the stash; a store to that half clears it).
//
// SDRAM port 2 (sdram.sv's toggle protocol) carries, in priority order: the ROM download's writes
// (sdram_download's dl_*), the write buffer, and line fills. That side is reset only at power-up (prst,
// the PLL's lock), never by the core reset: MiSTer holds the core reset for the whole download
// (LESSONS_LEARNED, "Never hold the memory path in the core reset").
// SDRAM words hold the even byte in [7:0]; the CPU is big-endian, so data is byte-swapped at this seam.

module vh_cpumem #(
	parameter [26:0] ROM_BASE  = 27'h0000000,
	parameter [26:0] WRAM_BASE = 27'h1800000,
	parameter [26:0] SPRHI_BASE = 27'h1a00000
) (
	input             clk,
	input             prst,            // power-up only: the port-2 side
	input             rst,

	// CPU
	input             bus_req,
	input             bus_wr,
	input             bus_io,
	input             bus_ifetch,
	input      [31:0] bus_addr,
	input      [3:0]  bus_be,
	input      [31:0] bus_wdata,
	output            bus_ack,
	output     [31:0] bus_rdata,

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

	// ROM download writes (sdram_download)
	input             dl_req,
	input      [26:0] dl_addr,
	input      [15:0] dl_data,
	input             dl_we16,
	output reg        dl_busy = 1'b0,

	// sdram.sv port 2
	output reg [26:1] mem_addr,
	output reg        mem_wrl,
	output reg        mem_wrh,
	output reg [15:0] mem_din,
	output reg        mem_dbl,
	output reg        mem_req = 1'b0,
	input             mem_ack,
	input      [63:0] mem_dout,
	input      [63:0] mem_doutb,

	output reg [31:0] st_imiss = 0,    // counters for the benches
	output reg [31:0] st_dmiss = 0,
	output reg [26:1] dbg_fill_a,      // the first line fill after reset: its address and first granule
	output reg [63:0] dbg_fill_d,      // (its second granule)
	output            dbg_miss,        // one clock per cache miss: dbg_miss_ic, the line in the cached space
	output            dbg_miss_ic,
	output     [21:4] dbg_miss_line,
	output            xflip_we         // a write to 0xe000xxxx (jmpbreak_flipscreen_w): bus_wdata, bus_be
);

// ---------------------------------------------------------------- decode
wire r_wram = bus_addr[31:21] == 11'd0;
wire r_rom  = bus_addr[31:20] == 12'hfff;
wire r_iram = bus_addr[31:29] == 3'b110;
wire r_spr  = bus_addr[31:16] == 16'h4000;
wire r_sprh = bus_addr[31:18] == 14'h1000 && bus_addr[17:16] != 2'd0;
wire r_pal  = bus_addr[31:16] == 16'h8000;
wire r_sd   = r_wram || r_rom || r_sprh;            // through the caches
wire [21:0] caddr = r_wram ? {1'b0, bus_addr[20:0]} : r_rom ? {2'b10, bus_addr[19:0]} : {4'b1100, bus_addr[17:0]};

// the cached space: 0x000000 work RAM, 0x200000 program ROM, 0x300000 sprite RAM above 64 KB
function [26:0] sdram_of(input [21:0] ca);
	sdram_of = !ca[21] ? WRAM_BASE + {6'd0, ca[20:0]} : !ca[20] ? ROM_BASE + {7'd0, ca[19:0]}
	                   : SPRHI_BASE + {9'd0, ca[17:0]};
endfunction

// SDRAM granule (4 little-endian-lane words, lowest address in [15:0]) -> 8 bytes, byte 0 in [63:56]
function [63:0] sw64(input [63:0] g);
	sw64 = {g[7:0], g[15:8], g[23:16], g[31:24], g[39:32], g[47:40], g[55:48], g[63:56]};
endfunction

// ---------------------------------------------------------------- state
localparam [3:0] S_INIT = 0, S_IDLE = 1, S_LOOK = 2, S_WLOOK = 3, S_MISS = 4, S_FILL = 5,
                 S_FILL2 = 6, S_ACK = 7;
localparam [1:0] SRC_REG = 0, SRC_IRAM = 1, SRC_SPR = 2, SRC_PAL = 3;

reg  [3:0]  st;
reg  [10:0] swc;
reg         ack_r;
reg  [1:0]  rsrc;
reg  [31:0] rdata_r;
reg  [21:0] fa;
reg         f_ic;               // the fill is for the I-cache
reg  [63:0] lg0, lg1;           // the line, swapped
reg         line_req, line_done;
reg         dbg_filled = 1'b0;

// the 8 bytes of the last cached instruction fetch
reg         sh_valid;
reg  [31:3] sh_a;
reg  [63:0] sh_q;

// D-side next-line prefetch
reg         pf_want, pf_valid, pf_kill, pf_use;
reg  [21:4] pf_want_line, pf_fl_line, pf_line;
reg  [63:0] pf0, pf1;

// write buffer: four stores, drained in order; the head goes out as its high halfword, then its low
(* ramstyle = "logic" *) reg  [21:0] wq_ca [0:3];   // registers: read combinationally (as RAM, the read of an entry written in the same clock depends on bypass logic Quartus may or may not add)
(* ramstyle = "logic" *) reg  [3:0]  wq_be [0:3];
(* ramstyle = "logic" *) reg  [31:0] wq_d  [0:3];
reg  [2:0]  wq_w = 3'd0, wq_r = 3'd0;
reg         wb_hi_done = 1'b0;              // the head's high halfword is written
wire        wb_valid = wq_w != wq_r;
wire        wb_full  = (wq_w - wq_r) == 3'd4;
wire [21:0] wb_ca = wq_ca[wq_r[1:0]];
wire [3:0]  wb_be = wq_be[wq_r[1:0]];
wire [31:0] wb_d  = wq_d[wq_r[1:0]];
wire        wb_hi = |wb_be[3:2] && !wb_hi_done;
wire        wb_lo = |wb_be[1:0];

wire idle_go = st == S_IDLE && bus_req;

// ---------------------------------------------------------------- caches
wire        ic_hit, dc_hit;
wire [63:0] ic_q, dc_q;
wire        sweep = st == S_INIT;
wire [7:0]  st_be8 = bus_addr[2] ? {4'b0, bus_be} : {bus_be, 4'b0};
wire        fill_we = st == S_FILL && (line_done || pf_use) || st == S_FILL2;
wire        fill_half = st == S_FILL2;
wire [63:0] fill_d = st == S_FILL2 ? lg1 : lg0;

vh_cache #(.AW(22), .LW(10)) u_ic (.clk(clk), .sweep(sweep), .sw_idx(swc[9:0]),
	.la(caddr), .hit(ic_hit), .q(ic_q),
	.fill_we(fill_we && f_ic), .fill_tag(fill_half), .fa(fa), .fill_half(fill_half), .fill_d(fill_d),
	.st_we(st == S_WLOOK && ic_hit), .st_be(st_be8), .st_d({bus_wdata, bus_wdata}));
vh_cache #(.AW(22), .LW(8)) u_dc (.clk(clk), .sweep(sweep), .sw_idx(swc[7:0]),
	.la(caddr), .hit(dc_hit), .q(dc_q),
	.fill_we(fill_we && !f_ic), .fill_tag(fill_half), .fa(fa), .fill_half(fill_half), .fill_d(fill_d),
	.st_we(st == S_WLOOK && dc_hit), .st_be(st_be8), .st_d({bus_wdata, bus_wdata}));

// ---------------------------------------------------------------- internal RAM
wire [31:0] iram_q;
vh_cache_ram #(.AW(10), .DW(32), .NB(4)) u_iram (.clk(clk), .addr(bus_addr[11:2]),
	.we(idle_go && bus_wr && !bus_io && r_iram), .be(bus_be), .wd(bus_wdata), .q(iram_q));

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

wire        look_hit = st == S_LOOK && (bus_ifetch ? ic_hit : dc_hit);
assign dbg_miss      = st == S_LOOK && !look_hit;
assign dbg_miss_ic   = bus_ifetch;
assign dbg_miss_line = caddr[21:4];
wire [63:0] look_q   = bus_ifetch ? ic_q : dc_q;
wire        sh_hit   = st == S_IDLE && bus_req && bus_ifetch && sh_valid && bus_addr[31:3] == sh_a;
assign bus_ack   = ack_r || look_hit || sh_hit || st == S_WLOOK || st == S_FILL2;
assign bus_rdata = sh_hit ? (bus_addr[2] ? sh_q[31:0] : sh_q[63:32]) :
                   st == S_LOOK ? (bus_addr[2] ? look_q[31:0] : look_q[63:32]) :
                   rsrc == SRC_IRAM ? iram_q : rsrc == SRC_SPR ? spr_rd : rsrc == SRC_PAL ? pal_rd : rdata_r;

// ---------------------------------------------------------------- CPU side and port 2
reg  [2:0]  m_who;              // 0 idle, 1 download, 2 buffer high half, 3 buffer low half, 4 line
localparam [2:0] W_NONE = 0, W_DL = 1, W_WBH = 2, W_WBL = 3, W_LINE = 4, W_PF = 5;
wire        m_free = m_who == W_NONE;
wire [26:0] wb_sa = sdram_of(wb_ca);
wire [26:0] fa_sa = sdram_of(fa);
wire [26:0] pf_sa = sdram_of({pf_want_line, 4'd0});
wire        pf_match = pf_valid && pf_line == caddr[21:4];

always @(posedge clk) begin
	line_done <= 1'b0;

	// port 2: one access at a time
	if (prst) begin
		m_who <= W_NONE;
		line_req <= 1'b0;
		dl_busy <= 1'b0;
		wq_w <= 3'd0; wq_r <= 3'd0; wb_hi_done <= 1'b0;
		mem_req <= mem_ack;            // nothing outstanding
	end else if (m_free) begin
		if (dl_req) begin
			mem_addr <= dl_addr[26:1];
			mem_wrl  <= dl_we16 || !dl_addr[0];
			mem_wrh  <= dl_we16 ||  dl_addr[0];
			mem_din  <= dl_we16 ? dl_data : {dl_data[7:0], dl_data[7:0]};
			mem_dbl  <= 1'b0;
			mem_req  <= ~mem_req;
			dl_busy  <= 1'b1;
			m_who    <= W_DL;
		end else if (wb_valid && wb_hi) begin
			mem_addr <= {wb_sa[26:2], 1'b0};
			mem_wrl  <= wb_be[3];
			mem_wrh  <= wb_be[2];
			mem_din  <= {wb_d[23:16], wb_d[31:24]};
			mem_dbl  <= 1'b0;
			mem_req  <= ~mem_req;
			m_who    <= W_WBH;
		end else if (wb_valid && wb_lo) begin
			mem_addr <= {wb_sa[26:2], 1'b1};
			mem_wrl  <= wb_be[1];
			mem_wrh  <= wb_be[0];
			mem_din  <= {wb_d[7:0], wb_d[15:8]};
			mem_dbl  <= 1'b0;
			mem_req  <= ~mem_req;
			m_who    <= W_WBL;
		end else if (line_req) begin
			mem_addr <= {fa_sa[26:4], 3'd0};
			mem_wrl  <= 1'b0;
			mem_wrh  <= 1'b0;
			mem_dbl  <= 1'b1;
			mem_req  <= ~mem_req;
			line_req <= 1'b0;
			m_who    <= W_LINE;
		end else if (pf_want) begin
			mem_addr <= {pf_sa[26:4], 3'd0};
			mem_wrl  <= 1'b0;
			mem_wrh  <= 1'b0;
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
			W_WBH:  if (wb_lo) wb_hi_done <= 1'b1; else wq_r <= wq_r + 3'd1;
			W_WBL:  begin wb_hi_done <= 1'b0; wq_r <= wq_r + 3'd1; end
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
		sh_valid <= 1'b0;
		dbg_filled <= 1'b0;
	end else case (st)
		S_INIT: begin
			swc <= swc + 11'd1;
			if (swc[10]) st <= S_IDLE;
		end
		S_IDLE: if (bus_req && !sh_hit) begin
			rsrc <= SRC_REG;
			if (bus_wr && bus_addr[31:3] == sh_a) sh_valid <= 1'b0;
			if (bus_io) begin
				rdata_r <= io_rdata;
				ack_r <= 1'b1; st <= S_ACK;
			end else if (r_iram || r_spr || r_pal) begin
				rsrc <= bus_wr ? SRC_REG : r_iram ? SRC_IRAM : r_spr ? SRC_SPR : SRC_PAL;
				ack_r <= 1'b1; st <= S_ACK;
			end else if (r_sd && !bus_wr) begin
				st <= S_LOOK;
			end else if ((r_wram || r_sprh) && bus_wr) begin
				if (!wb_full) begin
					if (pf_match) pf_valid <= 1'b0;
					if (m_who == W_PF && pf_fl_line == caddr[21:4]) pf_kill <= 1'b1;
					if (pf_want && pf_want_line == caddr[21:4]) pf_kill <= 1'b1;   // issued in this clock
					wq_ca[wq_w[1:0]] <= caddr;
					wq_be[wq_w[1:0]] <= bus_be;
					wq_d[wq_w[1:0]]  <= bus_wdata;
					wq_w <= wq_w + 3'd1;
					st <= S_WLOOK;
				end
			end else begin
				rdata_r <= 32'd0;
				ack_r <= 1'b1; st <= S_ACK;
			end
		end
		S_LOOK: begin
			if (look_hit) begin
				st <= S_IDLE;                 // acked in this clock
				if (bus_ifetch) begin sh_valid <= 1'b1; sh_a <= bus_addr[31:3]; sh_q <= ic_q; end
			end else begin
				fa <= caddr;
				f_ic <= bus_ifetch;
				if (bus_ifetch) st_imiss <= st_imiss + 1'd1;
				else st_dmiss <= st_dmiss + 1'd1;
				if (!bus_ifetch && pf_match) begin
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
			if (f_ic) begin
				sh_valid <= 1'b1; sh_a <= bus_addr[31:3]; sh_q <= fa[3] ? lg1 : lg0;
			end
			if (!f_ic) begin              // the next line, behind anything else on port 2
				pf_want <= 1'b1;
				pf_want_line <= fa[21:4] + 18'd1;
			end
			st <= S_FILL2;
		end
		S_FILL2: begin                    // acked in this clock, with rdata_r
			rsrc <= SRC_REG;
			st <= S_IDLE;
		end
		S_ACK: st <= S_IDLE;
		default: st <= S_IDLE;
	endcase
end

endmodule
