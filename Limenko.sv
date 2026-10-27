// SPDX-License-Identifier: GPL-3.0-or-later
//
// Limenko Power System 2 (MAME misc/limenko.cpp): Dynamite Bomber, Legend of Heroes, Super Bubble 2003, To Heart
// House, and Spotty on the same video chip; sets in scripts/build_mra_lm.py SETS. The Limenko revision of the
// Vamphalf project: the CPU, memory system, 93C46 and QS1000 are Vamphalf's modules.
//
// Framework glue: hps_io, PLL, resets, the ROM download (fast, from DDR3), inputs, the .nvm (the EEPROM, then
// hrthouse's NVRAM) and the video output chain. The board is rtl/lm_main.sv and rtl/video/lm_video.sv; the sound
// rtl/qs1000/vh_qs1000.sv in Limenko mode, or spotty's AT89C4051 and M6295 (rtl/sound/lm_spotty.sv).
//
// Clocks (rtl/pll, as Vamphalf.sv): clk_sys 56 MHz for everything, SDRAM included.

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

assign AUDIO_S   = 1;
assign AUDIO_MIX = status[48:47];

`include "rtl/lm_sdram_map.svh"
`include "build_id.v"

wire [1:0] ar = status[122:121];

`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
`endif

localparam CONF_STR = {
	"Limenko;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[65],Flip Screen,Off,On;",
	"DIP;",
	"O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"H4O[48:47],Stereo Mix,None,25%,50%,100%;",
	"-;",
	"O[94],CRT adjust,Off,On;",
	"H3O[99:95],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3O[106:100],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3O[112:107],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[82],Pause CPU,Off,On;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// entry i is joystick bit 4 + i, matching the .mra <buttons>
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause,Service Coin,Service Mode,Button 5,Button 6,Button 7;",
	"jn,A,B,X,Y,Start,Select,L,R;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire mono;                                  // spotty's sound is mono: no Stereo Mix
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;
wire  [7:0] ioctl_din;
wire        ioctl_upload;
reg         nvram_save = 1'b0;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({11'd0, mono, ~status[94], 1'b0, DEBUG_MENU_HIDE, 1'b0}),   // H1 Debug, H3 CRT adjust, H4 Stereo Mix

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	// the .mra's <nvram index="2">: the EEPROM, then hrthouse's NVRAM
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nvram_save),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.ps2_key(ps2_key)
);

// Clocks

wire clk_sys, clk_sdram_shifted, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram_shifted;

// Reset

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// The game is held until a ROM is in SDRAM and while the fast load copies it; the memory path is not
// (as Vamphalf.sv).
wire ldr_active;
reg  rom_loaded = 1'b0, dl_seen = 1'b0, ldr_active_d = 1'b0;
always @(posedge clk_sys) begin
	ldr_active_d <= ldr_active;
	if (ioctl_wr && ioctl_index == 16'd0) dl_seen <= 1'b1;
	if (dl_seen && !ioctl_download)       rom_loaded <= 1'b1;
	if (ldr_active_d && !ldr_active)      rom_loaded <= 1'b1;
end
wire dbg_hold;
wire core_reset = reset | ioctl_download | ~rom_loaded | ldr_active | dbg_hold;

// Fast ROM load, as Vamphalf.sv: with address="0x30000000" the image is in DDR3 and the copy starts on the next
// reset release, once per index-0 download.
reg  dl0_d = 1'b0, dl0_seen = 1'b0, dl_seen_wr = 1'b0, ldr_pending = 1'b0, ldr_start = 1'b0, ldr_done = 1'b0;
reg  nvm_seen = 1'b0;
wire dl0 = ioctl_download && ioctl_index == 16'd0;

// The video, lm_fb's DDR3 reads with it, is held with the game and from a reset until the copy has started: the
// copy shares the DDR3 port and ddram_phy takes any read data arriving while it waits as its own, so a line read
// still in flight shifts the whole image (board: black screen, CPU trapping at 0xfffffff0). The copy waits for
// 256 clocks of that hold, enough to drain the longest such read.
wire vid_rst = ~pll_locked | core_reset | ldr_pending | ldr_start;
reg  [8:0] vid_quiet = 9'd0;
always @(posedge clk_sys) vid_quiet <= !vid_rst ? 9'd0 : vid_quiet[8] ? vid_quiet : vid_quiet + 9'd1;

always @(posedge clk_sys) begin
	ldr_start <= 1'b0;
	dl0_d <= dl0;
	if (dl0 && !dl0_d) begin
		dl0_seen   <= 1'b1;
		dl_seen_wr <= 1'b0;
		ldr_done   <= 1'b0;
		nvm_seen   <= 1'b0;
	end else if (dl0 && ioctl_wr) dl_seen_wr <= 1'b1;
	if (ioctl_download && ioctl_wr && ioctl_index == 16'd2) nvm_seen <= 1'b1;
	if (reset) ldr_pending <= 1'b1;
	else if (ldr_pending && !ioctl_download && !ldr_active && vid_quiet[8]) begin
		ldr_pending <= 1'b0;
		if (dl0_seen && !dl_seen_wr && !ldr_done) begin
			ldr_start <= 1'b1;
			ldr_done  <= 1'b1;
		end
	end
end

// .mra mod byte

// <rom index="1"> (scripts/build_mra_lm.py): [2:0] the game (0 dynabomb, 1 sb2003, 2 legendoh, 3 hrthouse,
// 4 spotty), [4] a 1 MB program at 0xfff00000 (spotty)
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd1 && !ioctl_addr[0]) mod_byte <= ioctl_dout;
wire [2:0] game = mod_byte[2:0];
wire       prg1 = mod_byte[4];
localparam [2:0] G_DB = 0, G_SB = 1, G_LH = 2, G_HH = 3, G_SP = 4;
assign mono = game == G_SP;

// Inputs

// MiSTer joystick: 0 R, 1 L, 2 D, 3 U, buttons 1-4 at 4-7, Start 8, Coin 9, Pause 10, Service Coin 11,
// Service Mode 12, buttons 5-7 at 13-15. MAME's default keys (rtl/mame_keys.sv) ORed into the pads.
wire [31:0] key0, key1;
wire  [1:0] svc_coin;
mame_keys #(.BUTTONS(4), .START(8), .COIN(9), .PAUSE(10), .SERVICE(12)) u_keys (
	.clk(clk_sys), .ps2_key(ps2_key), .alt(1'b0), .key0(key0), .key1(key1), .svc_coin(svc_coin)
);
wire [31:0] joy0 = joystick_0 | key0;
wire [31:0] joy1 = joystick_1 | key1;
wire [31:0] joy2 = joystick_2, joy3 = joystick_3;
wire        svc_mode = joy0[12] | joy1[12];
wire        svc_coin1 = joy0[11] | joy1[11] | svc_coin[0];

// The ports' bits 31:16, active high here (inverted below), per limenko.cpp's INPUT_PORTS:
//   sb2003 (dynabomb, sb2003): IN0/IN1 U D L R, button 2, button 1, buttons 3, 4 (bits 16-23)
//   legendoh: IN0 P1 then P3, IN1 P2 then P4: U D L R, buttons 1-4
//   hrthouse: IN0 hold 2, hold 4, hold 1, hold 3, Start / Even, Take / Odd, Bet / Double Up
//   spotty: IN0 holds 1-4, Bet, Stop (take), Change (deal)
//   IN2: 16 START1, 17 START2, 18 COIN1, 19 COIN2, 20 SERVICE1, 21 service mode, 24 START3, 25 START4, 26 COIN3,
//   27 COIN4, 28 SERVICE2, 29 the "Sound Enable" DIP (0 = on; spotty's "Demo Sounds", 1 = on); lm_main sets the
//   security, EEPROM and spriteram bits. hrthouse: 20 unknown, 21 memory reset; spotty: 17, 20, 24-28 unused.
function automatic [7:0] lm_pl(input [31:0] j, input sb);   // U D L R, buttons 1-4 (sb2003's 2 and 1 swapped)
	lm_pl = {j[7], j[6], sb ? j[4] : j[5], sb ? j[5] : j[4], j[0], j[1], j[2], j[3]};
endfunction
// The .mra's <switches> (ioctl index 254): byte 0 bit 0 is IN2 bit 29 as the CPU reads it, bits 3:1 the QS1000
// sets' "Volume Boost" in 6 dB steps (HACKS.md). Before a .mra sends it, MAME's default and no boost.
reg [7:0] dsw = 8'h00;
reg       dsw_seen = 1'b0;
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd254 && ioctl_addr == 27'd0) begin
		dsw <= ioctl_dout;
		dsw_seen <= 1'b1;
	end
wire       dip29     = dsw_seen ? dsw[0] : game == G_SP;
wire [2:0] vol_boost = dsw_seen ? dsw[3:1] : 3'd0;

reg [15:0] in0_h, in1_h, in2_h;
always @* begin
	in0_h = 16'd0; in1_h = 16'd0;
	in2_h = {2'b00, ~dip29, 1'b0, 4'd0, 2'b00, svc_mode, svc_coin1, joy1[9], joy0[9], joy1[8], joy0[8]};
	case (game)
		G_LH: begin
			in0_h = {lm_pl(joy2, 1'b0), lm_pl(joy0, 1'b0)};
			in1_h = {lm_pl(joy3, 1'b0), lm_pl(joy1, 1'b0)};
			in2_h[12:8] = {joy2[11] | joy3[11], joy3[9], joy2[9], joy3[8], joy2[8]};
		end
		G_HH: begin
			in0_h[6:0] = {joy0[14], joy0[13], joy0[8], joy0[6], joy0[4], joy0[7], joy0[5]};
			in2_h[1:0] = 2'b00;
			in2_h[4] = 1'b0;
		end
		G_SP: begin
			in0_h[6:0] = {joy0[15], joy0[14], joy0[13], joy0[7], joy0[6], joy0[5], joy0[4]};
			in2_h[1] = 1'b0; in2_h[3] = 1'b0;  in2_h[4] = 1'b0;
		end
		default: begin
			in0_h[7:0] = lm_pl(joy0, 1'b1);
			in1_h[7:0] = lm_pl(joy1, 1'b1);
		end
	endcase
end
wire [15:0] in0 = ~in0_h, in1 = ~in1_h, in2 = ~in2_h;

// Pause: joystick bit 10 (or P) toggles; the Debug page's Pause CPU is ORed in
wire pause_btn = joy0[10] | joy1[10];
reg  pause_btn_d = 1'b0, pause_toggle = 1'b0;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                         pause_toggle <= 1'b0;
	else if (pause_btn & ~pause_btn_d) pause_toggle <= ~pause_toggle;
end
wire pause_cpu = pause_toggle | status[82];

// NVRAM

// The load byte stream: the HPS's, or the fast load's replay of the regions caught here (index 0).
wire        ldr_tb_wr;
wire [26:0] ldr_tb_addr;
wire  [7:0] ldr_tb_dout;
wire        lb_wr    = ldr_active ? ldr_tb_wr : ioctl_download && ioctl_wr;
wire [15:0] lb_index = ldr_active ? 16'd0 : ioctl_index;
wire [26:0] lb_addr  = ldr_active ? ldr_tb_addr : ioctl_addr;
wire  [7:0] lb_dout  = ldr_active ? ldr_tb_dout : ioctl_dout;

// The 93C46 is blank (all ones) from configuration until the first download; its image comes in the index-0
// stream at LM_EEPROM (erased in every set), a saved .nvm as index 2. Words are big-endian. hrthouse's NVRAM is
// filled with ones (nv_blank) at the start of the download, and the .nvm's bytes after the first 128 load it.
reg        ee_blank = 1'b1;
reg  [7:0] ee_hi;
reg        ee_we = 1'b0;
reg  [5:0] ee_wa;
reg [15:0] ee_wd;
reg [10:0] nv_blank_n = 11'd0;
wire       in_ee_rom = lb_index == 16'd0 && lb_addr[26:7] == LM_EEPROM[26:7];
wire       in_ee_nvm = lb_index == 16'd2 && lb_addr[26:7] == 20'd0;
wire [26:0] nv_off   = lb_addr - 27'h80;
wire        nv_load  = ioctl_download && ioctl_index == 16'd2;
wire        nv_ld_we = lb_wr && lb_index == 16'd2 && lb_addr[26:7] != 20'd0 && nv_off[26:12] == 15'd0;
always @(posedge clk_sys) begin
	ee_we <= 1'b0;
	if (ioctl_download) ee_blank <= 1'b0;
	if (dl0 && !dl0_d) nv_blank_n <= 11'd1100;
	else if (nv_blank_n != 11'd0) nv_blank_n <= nv_blank_n - 11'd1;
	if (lb_wr && (in_ee_rom || in_ee_nvm)) begin
		if (!lb_addr[0]) ee_hi <= lb_dout;
		else begin
			ee_we <= 1'b1;
			ee_wa <= lb_addr[6:1];
			ee_wd <= {ee_hi, lb_dout};
		end
	end
end
wire nv_blank = nv_blank_n != 11'd0 && game == G_HH;

// the .nvm upload reads the arrays; a save is requested a second after the game's last write
wire [15:0] ee_rd_data;
wire        ee_written;
wire  [7:0] nv_rd_data;
wire        nv_written;
wire [26:0] nv_rd_off = ioctl_addr - 27'h80;
assign ioctl_din = ioctl_addr[26:7] != 20'd0 ? nv_rd_data : ioctl_addr[0] ? ee_rd_data[7:0] : ee_rd_data[15:8];
reg  [25:0] ee_quiet = 26'd0;
reg         ee_dirty = 1'b0;
always @(posedge clk_sys) begin
	nvram_save <= 1'b0;
	if (ee_written || (nv_written && game == G_HH)) begin
		ee_dirty <= 1'b1;
		ee_quiet <= 26'd0;
	end else if (ee_dirty) begin
		ee_quiet <= ee_quiet + 26'd1;
		if (ee_quiet == 26'd56_000_000) begin
			ee_dirty   <= 1'b0;
			nvram_save <= 1'b1;
		end
	end
end

// Board

// the E1's 80 MHz (20 MHz x 4) as timer ticks: one every clock, a second in 3 of every 7
reg [2:0] tk7 = 3'd0;
always @(posedge clk_sys) tk7 <= (tk7 == 3'd6) ? 3'd0 : tk7 + 3'd1;
wire cpu_tick2 = tk7 == 3'd0 || tk7 == 3'd2 || tk7 == 3'd4;

wire        v0_we, v1_we, spr_bit, spr_cmd, v1_wait;
wire [3:0]  v0_be, v1_be;
wire [13:0] v0_addr, v1_addr;
wire [31:0] v0_wd, v1_wd, v0_rd, v1_rd;
wire        vblank_start;
wire [7:0]  snd_latch;
wire        snd_latch_wr;

wire        dl_req, dl_we16, dl_busy;
wire [26:0] dl_addr;
wire [15:0] dl_data;
wire        bdl_req;
wire [26:0] bdl_addr;
wire        ldl_req;
wire [26:0] ldl_addr;
wire [63:0] ldl_gdata;

sdram_download u_dl (
	.clk(clk_sys), .reset(~pll_locked),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
	.dl_req(bdl_req), .dl_addr(bdl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_busy(ldr_active ? 1'b0 : dl_busy)
);

// the fast load's copy: DDR3 into the download port's granule mode. The image ends at LM_GFX plus the set's
// graphics: 8 MB (dynabomb, sb2003), 18 MB (legendoh), 2 MB (hrthouse), 1 MB (spotty's 4bpp image).
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid;
wire [27:0] ldr_ddr_addr, ldr_tap_addr;
wire [63:0] ldr_ddr_rdata;

// DDR3: the fast load's copy while it runs (the video is held in reset), the sprite frame buffer otherwise
wire [7:0]  ldr_DDRAM_BURSTCNT, ldr_DDRAM_BE, fb_DDRAM_BURSTCNT, fb_DDRAM_BE;
wire [28:0] ldr_DDRAM_ADDR, fb_DDRAM_ADDR;
wire [63:0] ldr_DDRAM_DIN, fb_DDRAM_DIN;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE, fb_DDRAM_RD, fb_DDRAM_WE;
ddram_phy u_ldr_ddram (
	.clk(clk_sys), .reset(~pll_locked),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT),
	.DDRAM_ADDR(ldr_DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);
assign DDRAM_CLK      = clk_sys;
assign DDRAM_BURSTCNT = ldr_active ? ldr_DDRAM_BURSTCNT : fb_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_active ? ldr_DDRAM_ADDR     : fb_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_active ? ldr_DDRAM_DIN      : fb_DDRAM_DIN;
assign DDRAM_BE       = ldr_active ? ldr_DDRAM_BE       : fb_DDRAM_BE;
assign DDRAM_WE       = ldr_active ? ldr_DDRAM_WE       : fb_DDRAM_WE;
assign DDRAM_RD       = ldr_active ? ldr_DDRAM_RD       : fb_DDRAM_RD;

// the granules replayed byte by byte: the QS1000's u7 (the first 128 KB of LM_SNDCPU) and, unless a .nvm came
// first, the EEPROM image
wire ldr_tap = ldr_tap_addr[26:17] == LM_SNDCPU[26:17] || (ldr_tap_addr[26:7] == LM_EEPROM[26:7] && !nvm_seen);
wire [27:0] gfx_len = game == G_LH ? 28'h1200000 : game == G_HH ? 28'h0200000 : game == G_SP ? 28'h0100000 :
                      28'h0800000;

vh_rom_loader u_ldr (
	.clk(clk_sys), .reset(~pll_locked),
	.length({1'b0, LM_GFX} + gfx_len),
	.start(ldr_start), .busy(ldr_active),
	.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy),
	.ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
	.dl_req(ldl_req), .dl_addr(ldl_addr), .dl_gdata(ldl_gdata), .dl_busy(ldr_active ? dl_busy : 1'b0),
	.tap_addr(ldr_tap_addr), .tap_want(ldr_tap),
	.tb_wr(ldr_tb_wr), .tb_addr(ldr_tb_addr), .tb_dout(ldr_tb_dout)
);

assign dl_req  = ldr_active ? ldl_req  : bdl_req;
assign dl_addr = ldr_active ? ldl_addr : bdl_addr;

wire [26:1] m2_addr;
wire        m2_wrl, m2_wrh, m2_dbl, m2_req, m2_ack;
wire [15:0] m2_din;
wire [47:0] m2_dinx;
wire  [5:0] m2_wrx;
wire [63:0] m_dout, m_doutb;

wire        dbg_retire;
wire [26:1] dbg_fill_a;
wire [63:0] dbg_fill_d;
wire [31:0] dbg_pc, dbg_imiss, dbg_dmiss;

lm_main u_main (
	.clk(clk_sys), .prst(~pll_locked), .rst(core_reset), .game(game), .prg1(prg1), .pause(pause_cpu),
	.cpu_tick(1'b1), .cpu_tick2(cpu_tick2),
	.vblank_irq(vblank_start), .in0(in0), .in1(in1), .in2(in2), .spr_bit(spr_bit),
	.snd_latch(snd_latch), .snd_latch_wr(snd_latch_wr),
	.v0_we(v0_we), .v0_be(v0_be), .v0_addr(v0_addr), .v0_wd(v0_wd), .v0_rd(v0_rd),
	.v1_we(v1_we), .v1_be(v1_be), .v1_addr(v1_addr), .v1_wd(v1_wd), .v1_rd(v1_rd), .spr_cmd(spr_cmd), .v1_wait(v1_wait),
	.ee_blank(ee_blank), .ee_load_we(ee_we), .ee_load_addr(ee_wa), .ee_load_data(ee_wd),
	.ee_rd_addr(ioctl_addr[6:1]), .ee_rd_data(ee_rd_data), .ee_written(ee_written),
	.nv_blank(nv_blank), .nv_load(nv_load), .nv_load_we(nv_ld_we), .nv_load_addr(nv_off[11:0]), .nv_load_data(lb_dout),
	.nv_rd_addr(nv_rd_off[11:0]), .nv_rd_data(nv_rd_data), .nv_written(nv_written),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_g(ldr_active), .dl_gdata(ldl_gdata),
	.dl_busy(dl_busy),
	.mem_addr(m2_addr), .mem_wrl(m2_wrl), .mem_wrh(m2_wrh), .mem_din(m2_din), .mem_dinx(m2_dinx), .mem_wrx(m2_wrx),
	.mem_dbl(m2_dbl), .mem_req(m2_req), .mem_ack(m2_ack), .mem_dout(m_dout), .mem_doutb(m_doutb),
	.retire(dbg_retire), .retire_pc(dbg_pc), .retire_npc(), .retire_sr(), .st_imiss(dbg_imiss), .st_dmiss(dbg_dmiss),
	.dbg_rf_we(), .dbg_rf_wa(), .dbg_rf_wd(), .dbg_fill_a(dbg_fill_a), .dbg_fill_d(dbg_fill_d),
	.trace_start(24'hffffff), .trace_idx(12'd0), .trace_valid(), .trace_rec(), .trace_q(), .trace_count()
);

// Probes: Limenko_stp revision only (DEBUG_ISSP); scripts/read_issp.tcl decodes them.
`ifdef DEBUG_ISSP
reg  [31:0] dbg_ninstr = 0, dbg_dlbytes = 0;
reg  [15:0] dbg_cmds = 0;
reg  [7:0]  dbg_frames = 0;
always @(posedge clk_sys) begin
	if (dbg_retire) dbg_ninstr <= dbg_ninstr + 1'd1;
	if (spr_cmd) dbg_cmds <= dbg_cmds + 1'd1;
	if (vblank_start) dbg_frames <= dbg_frames + 1'd1;
	if (lb_wr && lb_index == 16'd0) dbg_dlbytes <= dbg_dlbytes + 1'd1;
end
// Instance F: [31:0] instructions retired, [63:32] last retired PC, [79:64] D-misses, [95:80] I-misses,
// [111:96] sprite-draw commands, [119:112] frames, [120] rom_loaded, [121] core_reset, [122] 0,
// [123] ioctl_download, [124] dl_seen, [125] ldr_active, [126] ldr_done, [127] pll_locked
issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(8)) u_issp_f (
	.clk(clk_sys),
	.probe({pll_locked, ldr_done, ldr_active, dl_seen, ioctl_download, 1'b0, core_reset, rom_loaded, dbg_frames, dbg_cmds,
	        dbg_imiss[15:0], dbg_dmiss[15:0], dbg_pc, dbg_ninstr}),
	.source()
);
// Instance D (as Vamphalf.sv): [63:0] the first line fill's second 8 bytes, [89:64] its SDRAM word address,
// [127:96] bytes downloaded (index 0). Source: [2] hold the core in reset
wire [7:0] dbg_src_d;
issp_probe #(.INSTANCE_ID("D"), .PROBE_W(128), .SOURCE_W(8)) u_issp_d (
	.clk(clk_sys), .probe({dbg_dlbytes, 6'd0, dbg_fill_a, dbg_fill_d}), .source(dbg_src_d)
);
reg [7:0] dbg_src_d1, dbg_src_d2;
always @(posedge clk_sys) begin dbg_src_d1 <= dbg_src_d; dbg_src_d2 <= dbg_src_d1; end
assign dbg_hold = dbg_src_d2[2];
`else
assign dbg_hold = 1'b0;
`endif

wire [7:0]  core_r, core_g, core_b;
wire        core_hs, core_vs, core_hb, core_vb, core_ce;

wire [26:1] m0_addr;
wire        m0_req, m0_ack;
// the graphics' 64-byte tiles: 8 MB, 18 MB (legendoh), 2 MB (hrthouse; spotty's 4bpp 1 MB as 2 MB of pixels)
lm_video #(.GFX_BASE(LM_GFX)) u_video (
	.clk(clk_sys), .rst(vid_rst),
	.tile_count(game == G_LH ? 19'h48000 : (game == G_HH || game == G_SP) ? 19'h08000 : 19'h20000),
	.tile_pow2(game != G_LH), .gfx4(game == G_SP), .flip(status[65]),
	.gfx_size(game == G_LH ? 26'h1200000 : (game == G_HH || game == G_SP) ? 26'h0200000 : 26'h0800000),
	.gfx_addr(m0_addr), .gfx_req(m0_req), .gfx_ack(m0_ack), .gfx_dout(m_dout), .dbg_overrun(), .dbg_spr_late(), .dbg_fb_late(),
	.v0_we(v0_we), .v0_be(v0_be), .v0_addr(v0_addr), .v0_wd(v0_wd), .v0_rd(v0_rd),
	.v1_we(v1_we), .v1_be(v1_be), .v1_addr(v1_addr), .v1_wd(v1_wd), .v1_rd(v1_rd),
	.spr_cmd(spr_cmd), .spr_bit(spr_bit), .v1_wait(v1_wait),
	.DDRAM_BURSTCNT(fb_DDRAM_BURSTCNT), .DDRAM_ADDR(fb_DDRAM_ADDR), .DDRAM_DIN(fb_DDRAM_DIN), .DDRAM_BE(fb_DDRAM_BE),
	.DDRAM_WE(fb_DDRAM_WE), .DDRAM_RD(fb_DDRAM_RD), .DDRAM_BUSY(DDRAM_BUSY | ldr_active), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY & ~ldr_active),
	.ce_pix(core_ce), .vid_r(core_r), .vid_g(core_g), .vid_b(core_b),
	.hblank(core_hb), .vblank(core_vb), .hsync(core_hs), .vsync(core_vs),
	.frame_start(), .vblank_start(vblank_start)
);

// The sound: the QS1000 on SDRAM port 1 (samples at LM_SAMPLES, the 8052's banks 2-7 at LM_SNDCPU), or on spotty
// its own board (samples at LM_SAMPLES) with the QS1000 held in reset. u7, or the AT89C4051's ROM, is caught on its
// way to SDRAM.
wire        snd_dl = lb_wr && lb_index == 16'd0 && lb_addr[26:17] == LM_SNDCPU[26:17];
wire [26:1] m1_addr, qs_addr, sp_addr;
wire        m1_req, m1_ack, qs_req, sp_req;
wire [63:0] m1_dout, m1_doutb;
wire signed [15:0] qs_l, qs_r, sp_out;
assign m1_addr = game == G_SP ? sp_addr : qs_addr;
assign m1_req  = game == G_SP ? sp_req : qs_req;

vh_qs1000 #(.SAMPLES_BASE(LM_SAMPLES), .SNDCPU_BASE(LM_SNDCPU)) u_snd (
	.clk(clk_sys), .rst(core_reset | game == G_SP), .lm(1'b1),
	.dl_we(snd_dl), .dl_addr(lb_addr[16:0]), .dl_data(lb_dout),
	.latch_wr(snd_latch_wr), .latch_d(snd_latch), .bal_pcb(1'b1),     // the chip's balance, looping and key-off fade,
	.loop_pcb(1'b1),                                                  // as Vamphalf.sv: the same QS1000 (MAME_KLUDGES.md)
	.sd_addr(qs_addr), .sd_req(qs_req), .sd_ack(m1_ack), .sd_dout(m1_dout), .sd_doutb(m1_doutb),
	.out_l(qs_l), .out_r(qs_r),
	.dbg_drops(), .dbg_stalls()
);

lm_spotty #(.SAMPLES_BASE(LM_SAMPLES)) u_spotty (
	.clk(clk_sys), .rst(core_reset | game != G_SP), .dl(ioctl_download | ldr_active),
	.dl_we(snd_dl && lb_addr[16:12] == 5'd0), .dl_addr(lb_addr[11:0]), .dl_data(lb_dout),
	.latch_wr(snd_latch_wr), .latch_d(snd_latch),
	.sd_addr(sp_addr), .sd_req(sp_req), .sd_ack(m1_ack), .sd_dout(m1_dout),
	.out(sp_out)
);

// The QS1000 games set the chip's volume register (8) about 27 dB below Vamphalf's misncrft, and MAME treats it as
// linear: "Volume Boost" shifts their output left, saturating (HACKS.md).
function automatic signed [15:0] boost(input signed [15:0] x, input [2:0] s);
	reg signed [22:0] y;
	begin
		y = {{7{x[15]}}, x} <<< s;
		boost = (y > 23'sd32767) ? 16'sd32767 : (y < -23'sd32768) ? -16'sd32768 : y[15:0];
	end
endfunction
reg signed [15:0] aud_l = 0, aud_r = 0;
always @(posedge clk_sys) begin
	aud_l <= game == G_SP ? sp_out : boost(qs_l, vol_boost);
	aud_r <= game == G_SP ? sp_out : boost(qs_r, vol_boost);
end
assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

`ifdef DEBUG_ISSP
// Instance A (Limenko_stp): the sound. [15:0] sound-latch writes, [23:16] the last one, [24] IN2 bit 29 as the
// CPU reads it ("Sound Enable", 0 = on), [47:32] QS1000 SDRAM requests, [63:48] the peak of |AUDIO_L|,
// [95:64] clocks with AUDIO_L non-zero
reg [15:0] dbg_latches = 0, dbg_sreq = 0, dbg_peak = 0;
reg [7:0]  dbg_latch_v = 0;
reg [31:0] dbg_nz = 0;
reg        dbg_qreq_d = 0;
wire signed [15:0] dbg_al = AUDIO_L;
wire [15:0] dbg_abs = dbg_al[15] ? 16'd0 - dbg_al : dbg_al;
always @(posedge clk_sys) begin
	dbg_qreq_d <= qs_req;
	if (snd_latch_wr) begin dbg_latches <= dbg_latches + 1'd1; dbg_latch_v <= snd_latch; end
	if (qs_req != dbg_qreq_d) dbg_sreq <= dbg_sreq + 1'd1;
	if (dbg_al != 16'sd0) dbg_nz <= dbg_nz + 1'd1;
	if (dbg_abs > dbg_peak) dbg_peak <= dbg_abs;
end
issp_probe #(.INSTANCE_ID("A"), .PROBE_W(128), .SOURCE_W(8)) u_issp_a (
	.clk(clk_sys), .probe({32'd0, dbg_nz, dbg_peak, dbg_sreq, 7'd0, dip29, dbg_latch_v, dbg_latches}), .source()
);
`endif

sdram #(.RFS_INTERVAL(10'd218)) u_sdram (
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(), .SDRAM_CKE(SDRAM_CKE),
	.init(~pll_locked), .clk(clk_sys), .rd_adj(2'd0),
	.addr0(m0_addr), .wrl0(1'b0), .wrh0(1'b0), .din0(16'd0), .dout0(m_dout), .req0(m0_req), .ack0(m0_ack),
	.dbl0(1'b0), .dout0b(m_doutb),
	.addr1(m1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1(16'd0), .dout1(m1_dout), .req1(m1_req), .ack1(m1_ack),
	.dbl1(1'b1), .dout1b(m1_doutb),
	.addr2(m2_addr), .wrl2(m2_wrl), .wrh2(m2_wrh), .din2(m2_din), .din2x(m2_dinx), .wrx2(m2_wrx), .dout2(), .req2(m2_req),
	.ack2(m2_ack), .dbl2(m2_dbl), .dout2b()
);

// Video

wire vga_de_raw;
wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb, crt_on, crt_ce;

vh_crt #(.HTOTAL(512), .CLK_PIX(7)) u_crt (
	.clk(clk_sys), .ce(core_ce),
	.adjust(status[94] & ~forced_scandoubler),
	.hsize_idx(status[99:95]), .hpos_idx(status[106:100]), .vshift_idx(status[112:107]),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .hb_in(core_hb), .vb_in(core_vb),
	.active(crt_on), .ce_out(crt_ce),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_on ? crt_ce : core_ce),

	.RGB_in(crt_on ? {crt_r, crt_g, crt_b} : {core_r, core_g, core_b}),
	.HBlank(crt_on ? crt_hb : core_hb),
	.VBlank(crt_on ? crt_vb : core_vb),
	.HSync(crt_on ? crt_hs : core_hs),
	.VSync(crt_on ? crt_vs : core_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// display aspect 4:3, the monitors' (CLAUDE.md)
video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_raw),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[68:66])
);

endmodule
