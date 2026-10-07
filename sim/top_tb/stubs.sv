// Simulation stand-ins for the MiSTer framework around emu (Vamphalf.sv). Only these are not the
// real thing; everything inside emu is. main.cpp drives the hps_io stub's registers directly.

module hps_io #(parameter CONF_STR = "", CONF_STR_BRAM = 0, PS2DIV = 0, WIDE = 0, VDNUM = 1, BLKSZ = 2,
                PS2WE = 0, STRLEN = 1, F12KEYMOD = 0) (
	input             clk_sys,
	inout      [45:0] HPS_BUS,
	inout      [35:0] EXT_BUS,
	output     [21:0] gamma_bus,
	output            forced_scandoubler,
	output     [1:0]  buttons,
	output     [127:0] status,
	input      [15:0] status_menumask,
	output     [31:0] joystick_0,
	output     [31:0] joystick_1,
	output            ioctl_download,
	output     [15:0] ioctl_index,
	output            ioctl_wr,
	output     [26:0] ioctl_addr,
	output     [7:0]  ioctl_dout,
	input             ioctl_wait,
	output            ioctl_upload,
	input             ioctl_upload_req,
	input      [7:0]  ioctl_upload_index,
	input      [7:0]  ioctl_din,
	output            ioctl_rd,
	output     [10:0] ps2_key
);
	reg        dl = 0, wr = 0;
	reg [15:0] idx = 0;
	reg [26:0] addr = 0;
	reg [7:0]  dout = 0;
	reg [127:0] st = 0;
	reg [31:0] j0 = 0, j1 = 0;
	assign gamma_bus = 0;
	assign forced_scandoubler = 0;
	assign buttons = 0;
	assign status = st;
	assign joystick_0 = j0;
	assign joystick_1 = j1;
	assign ioctl_download = dl;
	assign ioctl_index = idx;
	assign ioctl_wr = wr;
	assign ioctl_addr = addr;
	assign ioctl_dout = dout;
	assign ioctl_upload = 0;
	assign ioctl_rd = 0;
	assign ps2_key = 0;
endmodule

// the PLL: clk_sys is CLK_50M itself (main.cpp clocks it at the core's rate); locked after 64 clocks
module pll (
	input  refclk,
	input  rst,
	output outclk_0,
	output outclk_1,
	output locked
);
	reg [6:0] n = 0;
	always @(posedge refclk) if (!n[6]) n <= n + 1'd1;
	assign outclk_0 = refclk;
	assign outclk_1 = refclk;
	assign locked = n[6];
endmodule

module arcade_video #(parameter WIDTH = 320, DW = 8, GAMMA = 1) (
	input             clk_video,
	input             ce_pix,
	input  [DW-1:0]   RGB_in,
	input             HBlank,
	input             VBlank,
	input             HSync,
	input             VSync,
	output            CLK_VIDEO,
	output            CE_PIXEL,
	output     [7:0]  VGA_R,
	output     [7:0]  VGA_G,
	output     [7:0]  VGA_B,
	output            VGA_HS,
	output            VGA_VS,
	output            VGA_DE,
	output     [1:0]  VGA_SL,
	input      [2:0]  fx,
	input             forced_scandoubler,
	inout      [21:0] gamma_bus
);
	assign CLK_VIDEO = clk_video;
	assign CE_PIXEL = ce_pix;
	assign {VGA_R, VGA_G, VGA_B} = RGB_in;
	assign VGA_HS = HSync;
	assign VGA_VS = VSync;
	assign VGA_DE = ~(HBlank | VBlank);
	assign VGA_SL = 0;
endmodule

module video_freak (
	input             CLK_VIDEO,
	input             CE_PIXEL,
	input             VGA_VS,
	input      [11:0] HDMI_WIDTH,
	input      [11:0] HDMI_HEIGHT,
	output            VGA_DE,
	output     [12:0] VIDEO_ARX,
	output     [12:0] VIDEO_ARY,
	input             VGA_DE_IN,
	input      [11:0] ARX,
	input      [11:0] ARY,
	input      [11:0] CROP_SIZE,
	input      [4:0]  CROP_OFF,
	input      [2:0]  SCALE
);
	assign VGA_DE = VGA_DE_IN;
	assign VIDEO_ARX = {1'b0, ARX};
	assign VIDEO_ARY = {1'b0, ARY};
endmodule

module screen_rotate_two (
	input         CLK_VIDEO,
	input         CE_PIXEL,
	input   [7:0] VGA_R,
	input   [7:0] VGA_G,
	input   [7:0] VGA_B,
	input         VGA_HS,
	input         VGA_VS,
	input         VGA_DE,
	input         rotate_ccw,
	input         no_rotate,
	input         flip,
	input         two_screen,
	output        video_rotated,
	output            FB_EN,
	output      [4:0] FB_FORMAT,
	output     [11:0] FB_WIDTH,
	output     [11:0] FB_HEIGHT,
	output     [31:0] FB_BASE,
	output     [13:0] FB_STRIDE,
	input             FB_VBL,
	input             FB_LL,
	output            DDRAM_CLK,
	input             DDRAM_BUSY,
	output      [7:0] DDRAM_BURSTCNT,
	output     [28:0] DDRAM_ADDR,
	output     [63:0] DDRAM_DIN,
	output      [7:0] DDRAM_BE,
	output            DDRAM_WE,
	output            DDRAM_RD
);
	assign video_rotated = 0;
	assign {FB_EN, FB_FORMAT, FB_WIDTH, FB_HEIGHT, FB_BASE, FB_STRIDE} = 0;
	assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_WE, DDRAM_RD} = 0;
endmodule
