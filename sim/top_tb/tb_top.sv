// Bench top for the whole core as Quartus builds it: emu (Vamphalf.sv) with the framework stubbed
// (sim/top_tb/stubs.sv) and the SDRAM chip model on its pins.

module tb_top (
	input         clk,
	input         reset,          // the framework's RESET (MiSTer holds it through a download)
	output [7:0]  vga_r,
	output [7:0]  vga_g,
	output [7:0]  vga_b,
	output        vga_de,
	output        vga_vs,
	output        ce_pixel,
	output        led_user
);

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire [1:0]  SDRAM_BA;
wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_DQML, SDRAM_DQMH, SDRAM_CKE, SDRAM_CLK;
wire [45:0] HPS_BUS;
wire [3:0]  ADC_BUS;

emu u_emu (
	.CLK_50M(clk), .RESET(reset), .HPS_BUS(HPS_BUS),
	.CLK_VIDEO(), .CE_PIXEL(ce_pixel), .VIDEO_ARX(), .VIDEO_ARY(),
	.VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b), .VGA_HS(), .VGA_VS(vga_vs), .VGA_DE(vga_de),
	.VGA_F1(), .VGA_SL(), .VGA_SCALER(), .VGA_DISABLE(),
	.HDMI_WIDTH(12'd1920), .HDMI_HEIGHT(12'd1080), .HDMI_FREEZE(), .HDMI_BLACKOUT(), .HDMI_BOB_DEINT(),
	.FB_EN(), .FB_FORMAT(), .FB_WIDTH(), .FB_HEIGHT(), .FB_BASE(), .FB_STRIDE(), .FB_VBL(1'b0), .FB_LL(1'b0),
	.FB_FORCE_BLANK(),
	.LED_USER(led_user), .LED_POWER(), .LED_DISK(), .BUTTONS(),
	.CLK_AUDIO(1'b0), .AUDIO_L(), .AUDIO_R(), .AUDIO_S(), .AUDIO_MIX(),
	.ADC_BUS(ADC_BUS),
	.SD_SCK(), .SD_MOSI(), .SD_MISO(1'b0), .SD_CS(), .SD_CD(1'b0),
	.DDRAM_CLK(), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(), .DDRAM_ADDR(), .DDRAM_DOUT(64'd0),
	.DDRAM_DOUT_READY(1'b0), .DDRAM_RD(), .DDRAM_DIN(), .DDRAM_BE(), .DDRAM_WE(),
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
