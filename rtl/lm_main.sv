// The Limenko main board (limenko.cpp): E1-32XN CPU (spotty: GMS30C2232), its memory system (vh_cpumem in
// Limenko mode), the I/O map, the 93C46 and the sound latch.
//
// I/O space (limenko io_map, spotty io_map; the port is the CPU's I/O address >> 13, as aoh_io in vh_main):
//   0x0000 R IN0   0x0200 R IN1   0x0400 R IN2         inputs on bits 31:16, bits 15:0 read 1
//   0x1000 W coin counters (dropped)
//   0x1200 W EEPROM: bit 16 CS, 17 CLK, 18 DI          0x1400 W sound latch, bits 23:16
//   Unmapped ports read 0.
// IN2 as the sets have it (in2 gives the switches and buttons, active low; these bits are set here):
//   bit 22 the security bit: an IPT_CUSTOM with no handler, so its default: 0 on legendoh (IP_ACTIVE_HIGH), 1 on
//          the others (IP_ACTIVE_LOW)
//   bit 23 EEPROM DO
//   bit 31 spriteram_bit (spotty: bit 19)
// The 4 KB RAM at 0x40000000, mirrored to 0x40003fff (vh_cpumem lm_xram): hrthouse's NVRAM (0x40000000-0x40000fff)
// and spotty's RAM (0x40002000-0x400024d3); the other sets have their data ROM there.
//
// The vertical blank interrupt is INT1: MAME's irq0_line_hold asserts input line 0, held until the CPU takes it.

module lm_main (
	input             clk,
	input             prst,           // power-up reset of the memory side (not the core reset)
	input             rst,
	input      [2:0]  game,           // 0 dynabomb, 1 sb2003, 2 legendoh, 3 hrthouse, 4 spotty (build_mra_lm.py)
	input             prg1,           // a 1 MB program at 0xfff00000 (spotty)
	input             pause,
	input             cpu_tick,       // the CPU's clock as enables (80 MHz: two in some clocks), for its timer
	input             cpu_tick2,

	input             vblank_irq,     // one clock at the start of the vertical blank
	input      [15:0] in0,            // IN0..IN2 bits 31:16, active low
	input      [15:0] in1,
	input      [15:0] in2,
	input             spr_bit,        // spriteram_bit (lm_video)

	output reg [7:0]  snd_latch,
	output reg        snd_latch_wr,

	// video windows (lm_video): 0x80000000-0x8000ffff and 0x80010000-0x8001ffff, registered reads
	output            v0_we,
	output     [3:0]  v0_be,
	output     [13:0] v0_addr,
	output     [31:0] v0_wd,
	input      [31:0] v0_rd,
	output            v1_we,
	output     [3:0]  v1_be,
	output     [13:0] v1_addr,
	output     [31:0] v1_wd,
	input      [31:0] v1_rd,
	output            spr_cmd,        // a write to 0x8003e000 (spriteram_buffer_w)
	input             v1_wait,        // hold the CPU's writes to the v1 window (lm_video's sprite-list copy)

	// EEPROM image: load during the download, read back for the NVRAM save
	input             ee_blank,
	input             ee_load_we,
	input      [5:0]  ee_load_addr,
	input      [15:0] ee_load_data,
	input      [5:0]  ee_rd_addr,
	output     [15:0] ee_rd_data,
	output            ee_written,

	// hrthouse's NVRAM: filled with 0xff while nv_blank (1024 clocks or more; MAME's nvram_device default, all
	// ones), then written by the .nvm load (the CPU is in reset), read back for the save
	input             nv_blank,
	input             nv_load,
	input             nv_load_we,
	input      [11:0] nv_load_addr,
	input      [7:0]  nv_load_data,
	input      [11:0] nv_rd_addr,
	output     [7:0]  nv_rd_data,
	output            nv_written,

	// ROM download writes, and SDRAM port 2
	input             dl_req,
	input      [26:0] dl_addr,
	input      [15:0] dl_data,
	input             dl_we16,
	input             dl_g,
	input      [63:0] dl_gdata,
	output            dl_busy,
	output     [26:1] mem_addr,
	output            mem_wrl,
	output            mem_wrh,
	output     [15:0] mem_din,
	output     [47:0] mem_dinx,
	output      [5:0] mem_wrx,
	output            mem_dbl,
	output            mem_req,
	input             mem_ack,
	input      [63:0] mem_dout,
	input      [63:0] mem_doutb,

	// for the benches
	output            retire,
	output     [31:0] retire_pc,
	output     [31:0] retire_npc,
	output     [31:0] retire_sr,
	output     [31:0] st_imiss,
	output     [31:0] st_dmiss,
	output            dbg_rf_we,
	output     [5:0]  dbg_rf_wa,
	output     [31:0] dbg_rf_wd,
	output     [26:1] dbg_fill_a,      // the first line fill after reset: its SDRAM address and second granule
	output     [63:0] dbg_fill_d,

	// architectural trace (rtl/debug/vh_trace.sv), as vh_main
	input      [23:0] trace_start,
	input      [11:0] trace_idx,
	output            trace_valid,
	output    [187:0] trace_rec,
	output    [187:0] trace_q,
	output     [12:0] trace_count
);

`include "lm_sdram_map.svh"

localparam [2:0] G_DB = 0, G_SB = 1, G_LH = 2, G_HH = 3, G_SP = 4;

// ---------------------------------------------------------------- CPU
wire        bus_req, bus_wr, bus_io, bus_ack;
wire        if_req, if_ack;
wire [31:3] if_addr;
wire [63:0] if_data;
wire [31:0] bus_addr, bus_wdata, bus_rdata;
wire [3:0]  bus_be;
wire [6:0]  irq_ack;
reg         int1;

wire        la_req;
wire [31:0] la_addr;
`ifdef E1_PIPE
e1_pipe u_cpu (
	.la_req(la_req), .la_addr(la_addr),
`else
assign la_req = 1'b0;
assign la_addr = 32'd0;
e1_cpu u_cpu (
`endif
	.clk(clk), .reset(rst), .cen(1'b1),
	.bus_req(bus_req), .bus_wr(bus_wr), .bus_io(bus_io), .bus_addr(bus_addr),
	.bus_be(bus_be), .bus_wdata(bus_wdata), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
	.if_req(if_req), .if_addr(if_addr), .if_ack(if_ack), .if_data(if_data),
	.irq_in({6'd0, int1}), .irq_ack(irq_ack), .pause(pause), .tick(cpu_tick), .tick2(cpu_tick2),
	.retire(retire), .retire_pc(retire_pc), .retire_npc(retire_npc), .retire_sr(retire_sr),
	.dbg_rf_we(dbg_rf_we), .dbg_rf_wa(dbg_rf_wa), .dbg_rf_wd(dbg_rf_wd)
);

always @(posedge clk) begin
	if (rst) int1 <= 1'b0;
	else if (irq_ack[0]) int1 <= 1'b0;
	else if (vblank_irq) int1 <= 1'b1;
end

vh_trace u_trace (
	.clk(clk), .rst(rst), .start(trace_start),
	.retire(retire), .npc(retire_npc), .sr(retire_sr),
	.rf_we(dbg_rf_we), .rf_wa(dbg_rf_wa), .rf_wd(dbg_rf_wd),
	.bus_req(bus_req), .bus_ack(bus_ack), .bus_wr(bus_wr), .bus_io(bus_io),
	.bus_be(bus_be), .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
	.rec_valid(trace_valid), .rec(trace_rec), .rd_idx(trace_idx), .rd_q(trace_q), .count(trace_count)
);

// ---------------------------------------------------------------- memory
wire        io_rd, io_wr;
wire [18:0] io_port;
wire [31:0] io_wd;
reg  [31:0] io_rdata;
wire        x_we;
wire [3:0]  x_be;
wire [11:0] x_addr;
wire [31:0] x_wd, x_rd;
wire        xram = game == G_HH || game == G_SP;

vh_cpumem #(.ROM_BASE(LM_MAINCPU), .WRAM_BASE(LM_WRAM), .SPRHI_BASE(27'd0), .PRGLO_BASE(LM_PRGLO),
            .AOHPRG_BASE(27'd0), .DATA_BASE(LM_DATA)) u_mem (
	.clk(clk), .prst(prst), .rst(rst), .prg2(!prg1), .aoh(1'b0), .aoh_sys(32'd0), .aoh_p12(32'd0),
	.lm(1'b1), .lm_xram(xram), .pal_wait(v1_wait), .x_we(x_we), .x_be(x_be), .x_addr(x_addr), .x_wd(x_wd), .x_rd(x_rd), .lm_cmd(spr_cmd),
	.bus_req(bus_req), .bus_wr(bus_wr), .bus_io(bus_io), .bus_addr(bus_addr),
	.bus_be(bus_be), .bus_wdata(bus_wdata), .bus_ack(bus_ack), .bus_rdata(bus_rdata), .la_req(la_req), .la_addr(la_addr),
	.if_req(if_req), .if_addr(if_addr), .if_ack(if_ack), .if_data(if_data),
	.spr_we(v0_we), .spr_be(v0_be), .spr_addr(v0_addr), .spr_wd(v0_wd), .spr_rd(v0_rd),
	.pal_we(v1_we), .pal_be(v1_be), .pal_addr(v1_addr), .pal_wd(v1_wd), .pal_rd(v1_rd),
	.io_rd(io_rd), .io_wr(io_wr), .io_port(io_port), .io_wd(io_wd), .io_rdata(io_rdata), .io_late(1'b0),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_g(dl_g), .dl_gdata(dl_gdata), .dl_busy(dl_busy),
	.mem_addr(mem_addr), .mem_wrl(mem_wrl), .mem_wrh(mem_wrh), .mem_din(mem_din), .mem_dinx(mem_dinx), .mem_wrx(mem_wrx), .mem_dbl(mem_dbl),
	.mem_req(mem_req), .mem_ack(mem_ack), .mem_dout(mem_dout), .mem_doutb(mem_doutb),
	.st_imiss(st_imiss), .st_dmiss(st_dmiss), .dbg_fill_a(dbg_fill_a), .dbg_fill_d(dbg_fill_d),
	.dbg_miss(), .dbg_miss_ic(), .dbg_miss_line(),
	.xflip_we()
);

// the RAM at 0x40000000: the CPU on port A, or the blank sweep and the .nvm load while it is in reset; port B reads
// the NVRAM back. The .nvm holds the bytes in the CPU's order: byte k of a dword is bits 31-8k..24-8k.
wire [31:0] nvq;
wire [3:0]  nv_be = 4'b1000 >> nv_load_addr[1:0];
reg  [9:0]  nv_sw;
always @(posedge clk) nv_sw <= nv_blank ? nv_sw + 10'd1 : 10'd0;
vh_dpram #(.AW(10), .DW(32), .NBE(4)) u_x (
	.clk(clk), .a_ce(1'b1),
	.a_we(nv_blank ? 4'hf : nv_load ? (nv_load_we ? nv_be : 4'd0) : (x_we ? x_be : 4'd0)),
	.a_addr(nv_blank ? nv_sw : nv_load ? nv_load_addr[11:2] : x_addr[9:0]),
	.a_wd(nv_blank ? 32'hffffffff : nv_load ? {4{nv_load_data}} : x_wd), .a_rd(x_rd),
	.b_addr(nv_rd_addr[11:2]), .b_rd(nvq)
);
reg [1:0] nv_lane;
always @(posedge clk) nv_lane <= nv_rd_addr[1:0];
assign nv_rd_data = nvq[31 - 8 * nv_lane -: 8];
assign nv_written = x_we;

// ---------------------------------------------------------------- I/O
wire [12:0] pk = io_port[12:0];
wire p_in0 = pk == 13'h0000, p_in1 = pk == 13'h0200, p_in2 = pk == 13'h0400;
wire p_ee  = pk == 13'h1200, p_lat = pk == 13'h1400;

reg  ee_di, ee_clk, ee_cs;
wire ee_do;
vh_eeprom93c46 #(.CLK_KHZ(56000)) u_ee (
	.rst(rst), .blank(ee_blank), .clk(clk), .cs(ee_cs), .sk(ee_clk), .di(ee_di), .dout(ee_do), .dbg(),
	.load_we(ee_load_we), .load_addr(ee_load_addr), .load_data(ee_load_data),
	.rd_addr(ee_rd_addr), .rd_data(ee_rd_data), .written(ee_written)
);

reg [15:0] in2_v;
always @* begin
	in2_v = in2;
	in2_v[6] = game != G_LH;                    // bit 22, the security bit
	in2_v[7] = ee_do;                           // bit 23
	if (game == G_SP) in2_v[3] = spr_bit;       // bit 19
	else              in2_v[15] = spr_bit;      // bit 31
	io_rdata = 32'd0;
	if (p_in0) io_rdata = {in0, 16'hffff};
	if (p_in1) io_rdata = {in1, 16'hffff};
	if (p_in2) io_rdata = {in2_v, 16'hffff};
end

always @(posedge clk) begin
	snd_latch_wr <= 1'b0;
	if (rst) begin
		ee_di <= 1'b0; ee_clk <= 1'b0; ee_cs <= 1'b0;
	end else if (io_wr) begin
		if (p_ee) begin ee_cs <= io_wd[16]; ee_clk <= io_wd[17]; ee_di <= io_wd[18]; end
		if (p_lat) begin snd_latch <= io_wd[23:16]; snd_latch_wr <= 1'b1; end
	end
end

endmodule
