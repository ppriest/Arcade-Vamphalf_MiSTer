// Limenko system bench: the main board (lm_main), the video (lm_video), the real SDRAM controller and a
// command-decoding chip model. main.cpp writes the .mra image (scripts/build_mra_lm.py --image) into the chip
// model's array and the EEPROM image through ee_load_*, and drives the inputs.

module tb_lm (
	input             clk,
	input             prst,
	input             rst,
	input             vrst,             // the video's reset: on the board it runs while the CPU is held
	input      [2:0]  game,
	input             prg1,
	input             pause,
	input             flip,
	input      [15:0] in0,
	input      [15:0] in1,
	input      [15:0] in2,

	input             ee_blank,
	input             nv_blank,
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
	output            vblank_start,

	output            retire,
	output     [31:0] retire_pc,
	output     [31:0] retire_npc,
	output     [31:0] retire_sr,
	output     [31:0] st_imiss,
	output     [31:0] st_dmiss,
	output            snd_latch_wr,
	output     [7:0]  snd_latch,
	output            spr_cmd,
	output            dbg_rf_we,
	output     [5:0]  dbg_rf_wa,
	output     [31:0] dbg_rf_wd,
	// the QS1000 (Limenko mode): u7 through its download port while rst is held; each 8052 read of the data window
	// at the enable that takes it
	input             snd_dl_we,
	input      [16:0] snd_dl_addr,
	input      [7:0]  snd_dl_data,
	output            snd_xrd,
	output     [18:0] snd_xaddr,
	output     [7:0]  snd_xdata,
	output            snd_wait,
	// spotty's board: the M6295's ROM bus (rom_ok: rom_data is the byte at rom_addr), its writes and output
	output            sp_rom_ok,
	output     [17:0] sp_rom_addr,
	output     [7:0]  sp_rom_data,
	output            sp_oki_wr,
	output     [7:0]  sp_oki_din,
	output     [15:0] sp_out,
	output     [15:0] dbg_overrun,
	output     [15:0] dbg_spr_late,
	output     [15:0] dbg_fb_late
);

// DDR3 (the sprite frame buffer): 64K words from FB_BASE, as sim/lm_video_tb
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
	if (d_rd) begin ra <= d_addr[15:0]; rleft <= d_cnt; rlat <= 8'd40; end
	else if (rleft != 8'd0) begin
		if (rlat != 8'd0) rlat <= rlat - 8'd1;
		else begin d_dout <= ddr[ra]; d_ready <= 1'b1; ra <= ra + 16'd1; rleft <= rleft - 8'd1; end
	end
end

// the E1's 80 MHz (20 MHz x 4) from 56 MHz: a tick every clock and a second in 3 of every 7
reg [2:0] tk7 = 3'd0;
always @(posedge clk) tk7 <= tk7 == 3'd6 ? 3'd0 : tk7 + 3'd1;
wire cpu_tick2 = tk7 == 3'd0 || tk7 == 3'd2 || tk7 == 3'd4;

wire        v0_we, v1_we, spr_bit, v1_wait;
wire [3:0]  v0_be, v1_be;
wire [13:0] v0_addr, v1_addr;
wire [31:0] v0_wd, v1_wd, v0_rd, v1_rd;

wire [26:1] m2_addr;
wire        m2_wrl, m2_wrh, m2_dbl, m2_req, m2_ack;
wire [15:0] m2_din;
wire [47:0] m2_dinx;
wire  [5:0] m2_wrx;
wire [63:0] m_dout, m_doutb;

lm_main u_main (
	.clk(clk), .prst(prst), .rst(rst), .game(game), .prg1(prg1), .pause(pause), .cpu_tick(1'b1), .cpu_tick2(cpu_tick2),
	.vblank_irq(vblank_start), .in0(in0), .in1(in1), .in2(in2), .spr_bit(spr_bit),
	.snd_latch(snd_latch), .snd_latch_wr(snd_latch_wr),
	.v0_we(v0_we), .v0_be(v0_be), .v0_addr(v0_addr), .v0_wd(v0_wd), .v0_rd(v0_rd),
	.v1_we(v1_we), .v1_be(v1_be), .v1_addr(v1_addr), .v1_wd(v1_wd), .v1_rd(v1_rd), .spr_cmd(spr_cmd), .v1_wait(v1_wait),
	.ee_blank(ee_blank), .ee_load_we(ee_load_we), .ee_load_addr(ee_load_addr), .ee_load_data(ee_load_data),
	.ee_rd_addr(6'd0), .ee_rd_data(), .ee_written(),
	.nv_blank(nv_blank), .nv_load(1'b0), .nv_load_we(1'b0), .nv_load_addr(12'd0), .nv_load_data(8'd0), .nv_rd_addr(12'd0), .nv_rd_data(),
	.nv_written(),
	.dl_req(1'b0), .dl_addr(27'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_g(1'b0), .dl_gdata(64'd0), .dl_busy(),
	.mem_addr(m2_addr), .mem_wrl(m2_wrl), .mem_wrh(m2_wrh), .mem_din(m2_din), .mem_dinx(m2_dinx), .mem_wrx(m2_wrx),
	.mem_dbl(m2_dbl), .mem_req(m2_req), .mem_ack(m2_ack), .mem_dout(m_dout), .mem_doutb(m_doutb),
	.retire(retire), .retire_pc(retire_pc), .retire_npc(retire_npc), .retire_sr(retire_sr),
	.st_imiss(st_imiss), .st_dmiss(st_dmiss), .dbg_rf_we(dbg_rf_we), .dbg_rf_wa(dbg_rf_wa), .dbg_rf_wd(dbg_rf_wd),
	.trace_start(24'd0), .trace_idx(12'd0), .trace_valid(), .trace_rec(), .trace_q(), .trace_count()
);

wire [26:1] m0_addr;
wire        m0_req, m0_ack;
lm_video u_video (
	.clk(clk), .rst(vrst),
	.tile_count(game == 3'd2 ? 19'h48000 : (game == 3'd3 || game == 3'd4) ? 19'h08000 : 19'h20000),
	.tile_pow2(game != 3'd2), .gfx4(game == 3'd4), .flip(flip),
	.gfx_size(game == 3'd2 ? 26'h1200000 : (game == 3'd3 || game == 3'd4) ? 26'h0200000 : 26'h0800000),
	.gfx_addr(m0_addr), .gfx_req(m0_req), .gfx_ack(m0_ack), .gfx_dout(m_dout), .dbg_overrun(dbg_overrun),
	.v0_we(v0_we), .v0_be(v0_be), .v0_addr(v0_addr), .v0_wd(v0_wd), .v0_rd(v0_rd),
	.v1_we(v1_we), .v1_be(v1_be), .v1_addr(v1_addr), .v1_wd(v1_wd), .v1_rd(v1_rd),
	.spr_cmd(spr_cmd), .spr_bit(spr_bit), .v1_wait(v1_wait),
	.DDRAM_BURSTCNT(d_cnt), .DDRAM_ADDR(d_addr), .DDRAM_DIN(d_din), .DDRAM_BE(d_be), .DDRAM_WE(d_we),
	.DDRAM_RD(d_rd), .DDRAM_BUSY(1'b0), .DDRAM_DOUT(d_dout), .DDRAM_DOUT_READY(d_ready),
	.dbg_spr_late(dbg_spr_late), .dbg_fb_late(dbg_fb_late),
	.ce_pix(ce_pix), .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
	.hblank(hblank), .vblank(vblank), .hsync(), .vsync(),
	.frame_start(frame_start), .vblank_start(vblank_start)
);

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire [1:0]  SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;
wire        m1_ack;
wire [26:1] m1_addr, qs_addr, sp_addr;
wire        m1_req, qs_req, sp_req;
wire [63:0] m1_dout, m1_doutb;
assign m1_addr = game == 3'd4 ? sp_addr : qs_addr;
assign m1_req  = game == 3'd4 ? sp_req : qs_req;

vh_qs1000 #(.SAMPLES_BASE(27'h0400000), .SNDCPU_BASE(27'h0200000)) u_snd (
	.clk(clk), .rst(rst | game == 3'd4), .lm(1'b1),
	.dl_we(snd_dl_we), .dl_addr(snd_dl_addr), .dl_data(snd_dl_data),
	.latch_wr(snd_latch_wr), .latch_d(snd_latch), .bal_pcb(1'b0), .loop_pcb(1'b0),
	.sd_addr(qs_addr), .sd_req(qs_req), .sd_ack(m1_ack), .sd_dout(m1_dout), .sd_doutb(m1_doutb),
	.out_l(), .out_r(), .dbg_drops(), .dbg_stalls()
);

lm_spotty #(.SAMPLES_BASE(27'h0400000)) u_spotty (
	.clk(clk), .rst(rst | game != 3'd4), .dl(1'b0),
	.dl_we(snd_dl_we && snd_dl_addr[16:12] == 5'd0), .dl_addr(snd_dl_addr[11:0]), .dl_data(snd_dl_data),
	.latch_wr(snd_latch_wr), .latch_d(snd_latch),
	.sd_addr(sp_addr), .sd_req(sp_req), .sd_ack(m1_ack), .sd_dout(m1_dout),
	.out(sp_out)
);
assign sp_rom_ok   = u_spotty.oki_rom_ok;
assign sp_rom_addr = u_spotty.oki_rom_addr;
assign sp_rom_data = u_spotty.oki_rom_data;
assign sp_oki_wr   = u_spotty.oki_wr;
assign sp_oki_din  = u_spotty.oki_din;
assign snd_xrd   = u_snd.mcen && u_snd.x_acc && !u_snd.x_wr && u_snd.x_addr[15:8] != 8'd0;
assign snd_xaddr = {u_snd.p3_latch[2:0], u_snd.x_addr};
assign snd_xdata = u_snd.u_mcu.x_din;
assign snd_wait  = u_snd.x_wait;

sdram #(.RFS_INTERVAL(10'd218)) u_sdram (
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
	.init(1'b0), .clk(clk), .rd_adj(2'd0),
	.addr0(m0_addr), .wrl0(1'b0), .wrh0(1'b0), .din0(16'd0), .dout0(m_dout), .req0(m0_req), .ack0(m0_ack),
	.dbl0(1'b0), .dout0b(m_doutb),
	.addr1(m1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1(16'd0), .dout1(m1_dout), .req1(m1_req), .ack1(m1_ack),
	.dbl1(1'b1), .dout1b(m1_doutb),
	.addr2(m2_addr), .wrl2(m2_wrl), .wrh2(m2_wrh), .din2(m2_din), .din2x(m2_dinx), .wrx2(m2_wrx), .dout2(), .req2(m2_req),
	.ack2(m2_ack), .dbl2(m2_dbl), .dout2b()
);

sdram_chip_model_wide u_chip (
	.clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
);

endmodule
