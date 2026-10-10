// System bench top: the main board (vh_main), the video (vh_video), the graphics port, the real SDRAM
// controller and a command-decoding chip model. main.cpp loads the .mra image into the chip model's
// array (the download path has its own bench), the EEPROM image through ee_load_*, and drives inputs.

module tb_sys (
	input             clk,
	input             prst,
	input             rst,
	input             vrst,             // the video's reset: on the board it runs while the CPU is held
	input             board,
	input      [4:0]  family,           // the I/O map (vh_main); 0, 1 and 11 the QS1000 boards
	input             prg2,             // a 2 MB program (yorijori)
	input             bal_pcb,          // the QS1000 mix balance: 0 MAME's (the benches' reference), 1 the PCB's
	input             pause,
	input      [15:0] code_mask,
	input      [15:0] p1p2,
	input      [7:0]  system,
	input             flip_osd,

	// the ROM download as hps_io drives it (index 0)
	input             ioctl_download,
	input             ioctl_wr,
	input      [26:0] ioctl_addr,
	input      [7:0]  ioctl_dout,
	output            ioctl_wait,

	input             ee_blank,
	input             ee_load_we,
	input      [5:0]  ee_load_addr,
	input      [15:0] ee_load_data,

	output            ce_pix,
	output     [7:0]  vid_r,
	output     [7:0]  vid_g,
	output     [7:0]  vid_b,
	output            hblank,
	output            vblank,
	output            frame_start,
	output     [15:0] dbg_overrun,
	output     [12:0] dbg_maxbusy,

	output            retire,
	output     [31:0] retire_pc,
	output     [31:0] retire_npc,
	output     [31:0] retire_sr,
	output     [31:0] st_imiss,
	output     [31:0] st_dmiss,
	output            snd_latch_wr,
	output     [7:0]  snd_latch,
	output            game_flip,
	output            dbg_miss,
	output            dbg_miss_ic,
	output     [23:4] dbg_miss_line,
	output            dbg_rf_we,
	output     [5:0]  dbg_rf_wa,
	output     [31:0] dbg_rf_wd,
	input      [23:0] trace_start,
	output            trace_valid,
	output    [187:0] trace_rec,

	input             snd_dl_we,        // u7 into the sound board while rst is held
	input      [16:0] snd_dl_addr,
	input      [7:0]  snd_dl_data,
	output            snd_wave_wr,
	output     [4:0]  snd_wave_off,
	output     [7:0]  snd_wave_data,
	output            snd_tick,
	output            snd_mix_valid,
	output     [31:0] snd_mix_l,
	output     [31:0] snd_mix_r,
	output     [15:0] snd_drops,
	output     [15:0] snd_stalls,

	output            prot_wr,          // the FPGA protection's accesses (+prot)
	output            prot_rd,
	output            prot_tab16,
	output     [15:0] prot_wd,
	output     [15:0] prot_rdata,
	output signed [15:0] yo_l,           // the YM2151 + M6295 board's output
	output signed [15:0] yo_r
);

`include "vh_sdram_map.svh"

// CPU timer enable: 25 of every 28 clocks (50 MHz from 56)
reg [4:0] tk;
wire f_aoh = family == 5'd14;
reg [2:0] tk7 = 3'd0;                       // aoh's 80 MHz: 10 ticks in 7 clocks, a second in 3 of them
always @(posedge clk) tk7 <= (tk7 == 3'd6) ? 3'd0 : tk7 + 3'd1;
wire cpu_tick  = f_aoh || tk < 5'd25;
wire cpu_tick2 = f_aoh && (tk7 == 3'd0 || tk7 == 3'd2 || tk7 == 3'd4);
always @(posedge clk) tk <= (tk == 5'd27) ? 5'd0 : tk + 5'd1;

wire        spr_we, pal_we;
wire [3:0]  spr_be, pal_be;
wire [13:0] spr_addr, pal_addr;
wire [31:0] spr_wd, pal_wd, spr_rd, pal_rd;
wire        vblank_start;

wire        dl_req, dl_we16, dl_busy;
wire [26:0] dl_addr;
wire [15:0] dl_data;
sdram_download u_dl (
	.clk(clk), .reset(1'b0),
	.ioctl_download(ioctl_download), .ioctl_index(16'd0), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_busy(dl_busy)
);

wire [26:1] m2_addr;
wire        m2_wrl, m2_wrh, m2_dbl, m2_req, m2_ack;
wire [15:0] m2_din;
wire [47:0] m2_dinx;
wire  [5:0] m2_wrx;
wire [63:0] m_dout, m_doutb;

vh_main u_main (
	.clk(clk), .prst(prst), .rst(rst), .board(board), .family(family), .prg2(prg2), .pause(pause), .cpu_tick(cpu_tick), .cpu_tick2(cpu_tick2),
	.vblank_irq(vblank_start), .p1p2(p1p2), .system(system), .xbtn(7'h7f),
	.flip(game_flip), .snd_latch(snd_latch), .snd_latch_wr(snd_latch_wr),
	.ym_wr(ym_wr), .ym_a0(ym_a0), .oki_wr(oki_wr), .snd_wd(snd_wd), .oki_bank(oki_bank),
	.ym_dout(ym_dout), .oki_dout(oki_dout), .oki2_wr(oki2_wr), .oki2_dout(oki2_dout),
	.spr_we(spr_we), .spr_be(spr_be), .spr_addr(spr_addr), .spr_wd(spr_wd), .spr_rd(spr_rd),
	.pal_we(pal_we), .pal_be(pal_be), .pal_addr(pal_addr), .pal_wd(pal_wd), .pal_rd(pal_rd),
	.ee_blank(ee_blank), .ee_load_we(ee_load_we), .ee_load_addr(ee_load_addr), .ee_load_data(ee_load_data),
	.ee_rd_addr(6'd0), .ee_rd_data(), .ee_written(),
	.bk_load(1'b0), .bk_load_we(1'b0), .bk_load_addr(15'd0), .bk_load_data(8'd0),
	.bk_rd_addr(15'd0), .bk_rd_data(), .bk_written(),
.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_g(1'b0), .dl_gdata(64'd0), .dl_busy(dl_busy),
	.mem_addr(m2_addr), .mem_wrl(m2_wrl), .mem_wrh(m2_wrh), .mem_din(m2_din), .mem_dinx(m2_dinx), .mem_wrx(m2_wrx), .mem_dbl(m2_dbl),
	.mem_req(m2_req), .mem_ack(m2_ack), .mem_dout(m_dout), .mem_doutb(m_doutb),
	.retire(retire), .retire_pc(retire_pc), .retire_npc(retire_npc), .retire_sr(retire_sr),
	.dbg_fill_a(), .dbg_fill_d(), .dbg_miss(dbg_miss), .dbg_miss_ic(dbg_miss_ic), .dbg_miss_line(dbg_miss_line),
	.dbg_rf_we(dbg_rf_we), .dbg_rf_wa(dbg_rf_wa), .dbg_rf_wd(dbg_rf_wd),
	.trace_start(trace_start), .trace_idx(12'd0), .trace_valid(trace_valid), .trace_rec(trace_rec),
	.trace_q(), .trace_count(), .st_imiss(st_imiss), .st_dmiss(st_dmiss)
);

wire        gfx_req, gfx_rdy, gfx_dv;
wire [25:0] gfx_addr;
wire [31:0] gfx_data;

vh_video u_video (
	.clk(clk), .rst(vrst), .code_mask(code_mask), .palshift(family == 5'd7), .code17(family == 5'd12), .aoh(f_aoh),
	.spr_we(spr_we), .spr_be(spr_be), .spr_addr(spr_addr), .spr_wd(spr_wd), .spr_rd(spr_rd),
	.pal_we(pal_we), .pal_be(pal_be), .pal_addr(pal_addr), .pal_wd(pal_wd), .pal_rd(pal_rd),
	.flip(game_flip ^ flip_osd),
	.gfx_req(gfx_req), .gfx_rdy(gfx_rdy), .gfx_addr(gfx_addr), .gfx_dv(gfx_dv), .gfx_data(gfx_data),
	.ce_pix(ce_pix), .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
	.hblank(hblank), .vblank(vblank), .hsync(), .vsync(), .hpos(), .vpos(),
	.frame_start(frame_start), .vblank_start(vblank_start),
	.dbg_overrun(dbg_overrun), .dbg_maxbusy(dbg_maxbusy)
);

wire [26:1] m0_addr;
wire        m0_req, m0_ack;

vh_gfxport #(.GFX_BASE(SD_GFX), .GFXHI_BASE(SD_GFXHI)) u_gfx (
	.clk(clk), .prst(prst), .aoh(f_aoh), .gfx_req(gfx_req), .gfx_rdy(gfx_rdy), .gfx_addr(gfx_addr), .gfx_dv(gfx_dv), .gfx_data(gfx_data),
	.mem_addr(m0_addr), .mem_req(m0_req), .mem_ack(m0_ack), .mem_dout(m_dout), .mem_doutb(m_doutb)
);

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire [1:0]  SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;
wire [26:1] m1_addr, qs_addr, yo_addr;
wire        m1_req, m1_ack, qs_req, yo_req;
wire [63:0] m1_dout, m1_doutb;
wire        snd_qs = family < 5'd2 || family == 5'd11;
wire        ym_wr, ym_a0, oki_wr;
wire [7:0]  snd_wd, ym_dout, oki_dout;
wire [2:0]  oki_bank;
wire        oki2_wr;
wire [7:0]  oki2_dout;
assign m1_addr = snd_qs ? qs_addr : yo_addr;
assign m1_req  = snd_qs ? qs_req : yo_req;

vh_ymoki u_ymoki (
	.clk(clk), .rst(rst | snd_qs), .xtal14(family == 5'd7), .aoh(f_aoh), .dl(1'b0),
	.oki2_wr(oki2_wr), .oki2_dout(oki2_dout),
	.ym_wr(ym_wr), .ym_a0(ym_a0), .ym_din(snd_wd), .ym_dout(ym_dout),
	.oki_wr(oki_wr), .oki_din(snd_wd), .oki_dout(oki_dout), .bank(oki_bank), .banked(family == 5'd4 || family == 5'd10 || family == 5'd12 || family == 5'd13),
	.sd_addr(yo_addr), .sd_req(yo_req), .sd_ack(m1_ack), .sd_dout(m1_dout),
	.out_l(yo_l), .out_r(yo_r)
);

vh_qs1000 u_snd (
	.clk(clk), .rst(rst | ~snd_qs),
	.dl_we(snd_dl_we | (ioctl_download && ioctl_wr && ioctl_addr[26:17] == SD_SNDCPU[26:17])),
	.dl_addr(snd_dl_we ? snd_dl_addr : ioctl_addr[16:0]), .dl_data(snd_dl_we ? snd_dl_data : ioctl_dout),
	.latch_wr(snd_latch_wr), .latch_d(snd_latch), .bal_pcb(bal_pcb),
	.sd_addr(qs_addr), .sd_req(qs_req), .sd_ack(m1_ack), .sd_dout(m1_dout), .sd_doutb(m1_doutb),
	.out_l(), .out_r(),
	.dbg_drops(snd_drops), .dbg_stalls(snd_stalls)
);
assign prot_wr    = u_main.prot_wr;
assign prot_rd    = u_main.io_rd && (u_main.m_prt16 || u_main.m_prt8);
assign prot_tab16 = u_main.m_prt16;
assign prot_wd    = u_main.prot_wd;
assign prot_rdata = u_main.prot_rdata;
assign snd_wave_wr   = u_snd.wave_wr;
assign snd_wave_off  = u_snd.x_addr[4:0];
assign snd_wave_data = u_snd.x_dout;
assign snd_tick      = u_snd.tick;
assign snd_mix_valid = u_snd.u_voice.mix_valid;
assign snd_mix_l     = u_snd.u_voice.mix_l;
assign snd_mix_r     = u_snd.u_voice.mix_r;

sdram #(.RFS_INTERVAL(10'd218)) u_sdram (
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
	.init(1'b0), .clk(clk), .rd_adj(2'd0),
	.addr0(m0_addr), .wrl0(1'b0), .wrh0(1'b0), .din0(16'd0), .dout0(m_dout), .req0(m0_req), .ack0(m0_ack),
	.dbl0(1'b1), .dout0b(m_doutb),
	.addr1(m1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1(16'd0), .dout1(m1_dout), .req1(m1_req), .ack1(m1_ack),
	.dbl1(snd_qs), .dout1b(m1_doutb),
	.addr2(m2_addr), .wrl2(m2_wrl), .wrh2(m2_wrh), .din2(m2_din), .din2x(m2_dinx), .wrx2(m2_wrx), .dout2(), .req2(m2_req), .ack2(m2_ack),
	.dbl2(m2_dbl), .dout2b()
);

sdram_chip_model_wide u_chip (
	.clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
);

endmodule
