// Bench top for the whole Limenko core as Quartus builds it: emu (Limenko.sv) with the framework stubbed
// (sim/top_tb/stubs.sv) and the SDRAM chip model on its pins.

module tb_lm_top (
	input         clk,
	input         reset,          // the framework's RESET (MiSTer holds it through a download)
	output [7:0]  vga_r,
	output [7:0]  vga_g,
	output [7:0]  vga_b,
	output        vga_de,
	output        vga_vs,
	output        ce_pixel,
	output [15:0] audio_l,
	output [15:0] audio_r
);

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire [1:0]  SDRAM_BA;
wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_DQML, SDRAM_DQMH, SDRAM_CKE, SDRAM_CLK;
wire [45:0] HPS_BUS;
wire [3:0]  ADC_BUS;

// DDR3 as the Avalon port: 128 MB from word 0 of the address's low 24 bits (the image at 0x30000000 at index 0,
// the frame buffer at 0x34000000 at 0x800000). A read of BURSTCNT words is taken when BUSY is low and answered
// from 12 clocks later, a word a clock; reads are pipelined as on the board: BUSY does not wait for a read's
// data, so up to four reads are outstanding and answered in order. A burst write takes ADDR and BURSTCNT on its
// first beat and a word on every clock WE is high and BUSY low, BE per byte. BUSY is high about one clock in
// four (an LFSR).
reg  [63:0] ddr_mem [0:(1 << 24) - 1];
wire        DDRAM_RD, DDRAM_WE;
wire [28:0] DDRAM_ADDR;
wire [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
wire [63:0] DDRAM_DIN;
reg         ddr_rdy = 1'b0;
reg  [63:0] ddr_q;
reg  [15:0] ddr_lfsr = 16'hace1;
reg  [7:0]  wr_left = 8'd0;
reg  [23:0] wr_a;
// the read queue: address, count, the clock it may start
reg  [23:0] rq_a [0:3];
reg  [7:0]  rq_n [0:3];
reg  [31:0] rq_t [0:3];
reg  [1:0]  rq_w = 2'd0, rq_r = 2'd0;
reg  [2:0]  rq_used = 3'd0;
reg  [31:0] now = 32'd0;
wire        ddr_busy = ddr_lfsr[1:0] == 2'd0 || rq_used == 3'd4;
wire [23:0] w_a = wr_left == 8'd0 ? DDRAM_ADDR[23:0] : wr_a;
wire        rq_push = DDRAM_RD && !ddr_busy;
wire        rq_pop  = rq_used != 3'd0 && now >= rq_t[rq_r] && rq_n[rq_r] == 8'd1;
integer     bi;
always @(posedge clk) begin
	now <= now + 32'd1;
	ddr_lfsr <= {ddr_lfsr[14:0], ddr_lfsr[15] ^ ddr_lfsr[13] ^ ddr_lfsr[12] ^ ddr_lfsr[10]};
	ddr_rdy  <= 1'b0;
	if (rq_used != 3'd0 && now >= rq_t[rq_r]) begin
		ddr_rdy <= 1'b1;
		ddr_q <= ddr_mem[rq_a[rq_r]];
		rq_a[rq_r] <= rq_a[rq_r] + 24'd1;
		rq_n[rq_r] <= rq_n[rq_r] - 8'd1;
		if (rq_n[rq_r] == 8'd1) rq_r <= rq_r + 2'd1;
	end
	if (rq_push) begin
		rq_a[rq_w] <= DDRAM_ADDR[23:0];
		rq_n[rq_w] <= DDRAM_BURSTCNT == 8'd0 ? 8'd1 : DDRAM_BURSTCNT;
		rq_t[rq_w] <= now + 32'd12;
		rq_w <= rq_w + 2'd1;
	end
	rq_used <= rq_used + {2'd0, rq_push} - {2'd0, rq_pop};
	if (DDRAM_WE && !ddr_busy) begin
		for (bi = 0; bi < 8; bi = bi + 1)
			if (DDRAM_BE[bi]) ddr_mem[w_a][8 * bi +: 8] <= DDRAM_DIN[8 * bi +: 8];
		wr_a <= w_a + 24'd1;
		wr_left <= wr_left == 8'd0 ? DDRAM_BURSTCNT - 8'd1 : wr_left - 8'd1;
	end
end

emu u_emu (
	.CLK_50M(clk), .RESET(reset), .HPS_BUS(HPS_BUS),
	.CLK_VIDEO(), .CE_PIXEL(ce_pixel), .VIDEO_ARX(), .VIDEO_ARY(),
	.VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b), .VGA_HS(), .VGA_VS(vga_vs), .VGA_DE(vga_de),
	.VGA_F1(), .VGA_SL(), .VGA_SCALER(), .VGA_DISABLE(),
	.HDMI_WIDTH(12'd1920), .HDMI_HEIGHT(12'd1080), .HDMI_FREEZE(), .HDMI_BLACKOUT(), .HDMI_BOB_DEINT(),
	.LED_USER(), .LED_POWER(), .LED_DISK(), .BUTTONS(),
	.CLK_AUDIO(1'b0), .AUDIO_L(audio_l), .AUDIO_R(audio_r), .AUDIO_S(), .AUDIO_MIX(),
	.ADC_BUS(ADC_BUS),
	.SD_SCK(), .SD_MOSI(), .SD_MISO(1'b0), .SD_CS(), .SD_CD(1'b0),
	.DDRAM_CLK(), .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(ddr_q),
	.DDRAM_DOUT_READY(ddr_rdy), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE),
	.UART_CTS(1'b0), .UART_RTS(), .UART_RXD(1'b0), .UART_TXD(), .UART_DTR(), .UART_DSR(1'b0),
	.USER_IN(7'd0), .USER_OUT(), .OSD_STATUS(1'b0)
);

sdram_chip_model_wide u_chip (
	.clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
);

endmodule
