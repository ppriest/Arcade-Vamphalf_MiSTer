// SPDX-License-Identifier: GPL-3.0-or-later
//
// Vamphalf (MAME misc/vamphalf.cpp): Mission Craft and Wivern Wings.
//
// Framework glue: hps_io, PLL, resets, the ROM download, inputs, the EEPROM's .nvm, and the video
// output chain. The board is rtl/vh_main.sv (CPU, memory, I/O) and rtl/video/vh_video.sv.
//
// Clocks (rtl/pll): clk_sys 56 MHz for everything, SDRAM included; SDRAM_CLK the same lagging by T - 3 ns (rtl/pll/pll_0002.v).

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
assign FB_FORCE_BLANK = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

// no sound yet (Phase 3)
assign AUDIO_S   = 1;
assign AUDIO_MIX = status[48:47];
assign AUDIO_L   = snd_qs ? qs_l : yo_l;
assign AUDIO_R   = snd_qs ? qs_r : yo_r;

//////////////////////////////////////////////////////////////////

`include "rtl/vh_sdram_map.svh"
`include "build_id.v"

wire [1:0] ar = status[122:121];

// Rotation: Auto follows the set (the .mra's mod byte: Mission Craft ROT90, Wivern Wings ROT270, most others ROT0).
wire       board;
wire [1:0] game_rot;                 // 0 ROT0, 1 ROT90, 2 ROT270
wire [1:0] rot_sel    = status[64:63];
wire       rotate_en  = (rot_sel == 2'd0) ? game_rot != 2'd0 : rot_sel != 2'd1;
wire       rotate_ccw = (rot_sel == 2'd0) ? game_rot == 2'd2 : rot_sel == 2'd3;

// 4:3 screen, 3:4 when rotated
wire [11:0] base_arx = rotate_en ? 12'd3 : 12'd4;
wire [11:0] base_ary = rotate_en ? 12'd4 : 12'd3;

`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
`endif

localparam CONF_STR = {
	"Vamphalf;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[64:63],Rotation,Auto,Off,CW,CCW;",
	"O[65],Flip Screen,Off,On;",
	"O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[48:47],Stereo Mix,None,25%,50%,100%;",
	"-;",
	"O[94],CRT adjust,Off,On;",
	"H3O[99:95],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3O[106:100],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3O[112:107],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"O[8],Service Mode,Off,On;",
	"-;",
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[82],Pause CPU,Off,On;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// entry i is joystick bit 4 + i, matching the .mra <buttons>
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause,Service;",
	"jn,A,B,X,Y,Start,Select,L,R;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire [31:0] joystick_0, joystick_1;

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
	.status_menumask({12'd0, ~status[94], 1'b0, DEBUG_MENU_HIDE, 1'b0}),   // H1 Debug, H3 CRT adjust

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	// the .mra's <nvram index="2" size="128"/>: the EEPROM
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nvram_save),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

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

///////////////////////   RESET   ////////////////////////////////

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// The game is held until a ROM is in SDRAM (rom_loaded, by either path) and while the fast load copies
// it (ldr_active); the memory path is not (LESSONS_LEARNED, "Never hold the memory path in the core
// reset").
wire ldr_active;
reg  rom_loaded = 1'b0, dl_seen = 1'b0, ldr_active_d = 1'b0;
always @(posedge clk_sys) begin
	ldr_active_d <= ldr_active;
	if (ioctl_wr && ioctl_index == 16'd0) dl_seen <= 1'b1;
	if (dl_seen && !ioctl_download)       rom_loaded <= 1'b1;
	if (ldr_active_d && !ldr_active)      rom_loaded <= 1'b1;   // the copy finished
end
wire [1:0] dbg_rd_adj;              // probe source (Vamphalf_stp); 0 in the release build
wire       dbg_hold;
wire core_reset = reset | ioctl_download | ~rom_loaded | ldr_active | dbg_hold;

// Fast ROM load (rtl/memory/vh_rom_loader.sv; trigger after Arcade-Seta_MiSTer's Seta.sv, with
// Arcade-JalecoMS32_MiSTer's dl0_seen). With address="0x30000000" on the .mra's index-0 ROM the HPS
// puts the image in DDR3 and the download has no ioctl_wr; the copy starts on the next reset release,
// once per index-0 download. A download that streams bytes is a byte-path load and is not copied over.
reg  dl0_d = 1'b0, dl0_seen = 1'b0, dl_seen_wr = 1'b0, ldr_pending = 1'b0, ldr_start = 1'b0, ldr_done = 1'b0;
reg  nvm_seen = 1'b0;
wire dl0 = ioctl_download && ioctl_index == 16'd0;
always @(posedge clk_sys) begin
	ldr_start <= 1'b0;
	dl0_d <= dl0;
	if (dl0 && !dl0_d) begin
		dl0_seen   <= 1'b1;
		dl_seen_wr <= 1'b0;
		ldr_done   <= 1'b0;
		nvm_seen   <= 1'b0;
	end else if (dl0 && ioctl_wr) dl_seen_wr <= 1'b1;
	// a .nvm (index 2) loaded before the copy keeps the EEPROM: the copy does not replay the default
	if (ioctl_download && ioctl_wr && ioctl_index == 16'd2) nvm_seen <= 1'b1;
	if (reset) ldr_pending <= 1'b1;
	else if (ldr_pending && !ioctl_download && !ldr_active) begin
		ldr_pending <= 1'b0;
		if (dl0_seen && !dl_seen_wr && !ldr_done) begin
			ldr_start <= 1'b1;
			ldr_done  <= 1'b1;
		end
	end
end

///////////////////   .mra: mod byte   ///////////////////////////

// <rom index="1">, two bytes (scripts/build_mra.py FAMILIES):
//   byte 0: [0] the E1-32 board, [2:1] rotation (0 ROT0, 1 ROT90, 2 ROT270), [7:3] the I/O map (vh_main family)
//   byte 1: [0] 16-bit sprite codes (gfx above 8 MB; 15-bit otherwise)
reg [7:0] mod_byte = 8'd0, mod_byte1 = 8'd0;
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd1) begin
		if (ioctl_addr[0]) mod_byte1 <= ioctl_dout;
		else mod_byte <= ioctl_dout;
	end
assign board    = mod_byte[0];
assign game_rot = mod_byte[2:1];
wire [4:0] family = mod_byte[7:3];
wire       snd_qs = family < 5'd2;   // the QS1000 boards; the others have the YM2151 + M6295
wire       f_suplup = family == 5'd7;   // the SUPLUP board: 14.318181 MHz sound clocks, colour in word 2's high byte

///////////////////////   INPUTS   ///////////////////////////////

// MiSTer joystick: 0 R, 1 L, 2 D, 3 U, buttons 1-4 at 4-7, Start 8, Coin 9, Pause 10, Service 11.
// MAME "common" P1_P2, active low: per player U D L R, buttons 1-4.
function automatic [7:0] vh_port(input [31:0] j);
	vh_port = {j[7], j[6], j[5], j[4], j[0], j[1], j[2], j[3]};
endfunction
// MAME's default keys (rtl/mame_keys.sv) ORed into the pads. F2 is MAME's service switch (SYSTEM bits 3
// and 4, IPT_SERVICE), so it goes to a joystick bit no pad button drives (12); 9 is SERVICE1.
wire [31:0] key0, key1;
wire  [1:0] svc_coin;
mame_keys #(.BUTTONS(4), .START(8), .COIN(9), .PAUSE(10), .SERVICE(12)) u_keys (
	.clk(clk_sys), .ps2_key(ps2_key), .key0(key0), .key1(key1), .svc_coin(svc_coin)
);
wire        key_f2 = key0[12];
wire        dbg_coin, dbg_start, dbg_b1;         // the probe's inputs (Vamphalf_stp only)
wire [31:0] joy0 = joystick_0 | {key0[31:13], 1'b0, key0[11:5], key0[4] | dbg_b1, key0[3:0]};
wire [31:0] joy1 = joystick_1 | key1;
wire [15:0] p1p2 = ~{vh_port(joy1), vh_port(joy0)};
// SYSTEM: COIN1, SERVICE1, COIN2, SERVICE, service mode switch, unused, START1, START2
wire [7:0]  sys_in = ~{joy1[8], joy0[8] | dbg_start, 1'b0, status[8] | key_f2, key_f2,
                       joy1[9], joy0[11] | joy1[11] | svc_coin[0], joy0[9] | dbg_coin};

// Pause: joystick bit 10 (or P) toggles; the Debug page's Pause CPU is ORed in
wire pause_btn = joy0[10] | joy1[10];
reg  pause_btn_d = 1'b0, pause_toggle = 1'b0;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                         pause_toggle <= 1'b0;
	else if (pause_btn & ~pause_btn_d) pause_toggle <= ~pause_toggle;
end
wire pause_cpu = pause_toggle | status[82];

///////////////////////   EEPROM   ///////////////////////////////

// Blank (a new part) from configuration until the first download; the set's default image arrives in
// the index-0 stream at SD_EEPROM (Mission Craft), the saved .nvm as index 2 after it. Words are
// big-endian: the even byte is the high one.
// The load byte stream: the HPS's, or the fast load's replay of the regions caught here (index 0).
wire        ldr_tb_wr;
wire [26:0] ldr_tb_addr;
wire  [7:0] ldr_tb_dout;
wire        lb_wr    = ldr_active ? ldr_tb_wr : ioctl_download && ioctl_wr;
wire [15:0] lb_index = ldr_active ? 16'd0 : ioctl_index;
wire [26:0] lb_addr  = ldr_active ? ldr_tb_addr : ioctl_addr;
wire  [7:0] lb_dout  = ldr_active ? ldr_tb_dout : ioctl_dout;

reg        ee_blank = 1'b1;
reg  [7:0] ee_hi;
reg        ee_we = 1'b0;
reg  [5:0] ee_wa;
reg [15:0] ee_wd;
wire       in_ee_rom = lb_index == 16'd0 && lb_addr[26:7] == SD_EEPROM[26:7];
wire       in_ee_nvm = lb_index == 16'd2 && lb_addr[26:7] == 20'd0;
always @(posedge clk_sys) begin
	ee_we <= 1'b0;
	if (ioctl_download) ee_blank <= 1'b0;
	if (lb_wr && (in_ee_rom || in_ee_nvm)) begin
		if (!lb_addr[0]) ee_hi <= lb_dout;
		else begin
			ee_we <= 1'b1;
			ee_wa <= lb_addr[6:1];
			ee_wd <= {ee_hi, lb_dout};
		end
	end
end

// the .nvm upload reads the array; a save is requested a second after the game's last write
wire [15:0] ee_rd_data;
wire        ee_written;
assign ioctl_din = ioctl_addr[0] ? ee_rd_data[7:0] : ee_rd_data[15:8];
reg  [25:0] ee_quiet = 26'd0;
reg         ee_dirty = 1'b0;
always @(posedge clk_sys) begin
	nvram_save <= 1'b0;
	if (ee_written) begin
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

///////////////////////   THE BOARD   ////////////////////////////

reg [4:0] tk = 5'd0;                       // the CPU's timer: 25 enables in 28 clocks, 50 MHz
wire cpu_tick = tk < 5'd25;
always @(posedge clk_sys) tk <= (tk == 5'd27) ? 5'd0 : tk + 5'd1;

wire        spr_we, pal_we;
wire [3:0]  spr_be, pal_be;
wire [13:0] spr_addr, pal_addr;
wire [31:0] spr_wd, pal_wd, spr_rd, pal_rd;
wire        vblank_start, game_flip;
wire [7:0]  snd_latch;
wire        snd_latch_wr;
wire        ym_wr, ym_a0, oki_wr;
wire [7:0]  snd_wd, ym_dout, oki_dout;
wire [1:0]  oki_bank;

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

// the fast load's copy: DDR3 through ddram_phy (muxed with the rotator below) into the download port's
// granule mode. The copy covers the image: the graphics region ends 8 MB or 16 MB above SD_GFX
// (mod byte 1 bit 0, scripts/build_mra.py).
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid;
wire [27:0] ldr_ddr_addr, ldr_tap_addr;
wire [63:0] ldr_ddr_rdata;
wire [7:0]  ldr_DDRAM_BURSTCNT, ldr_DDRAM_BE;
wire [28:0] ldr_DDRAM_ADDR;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE;
wire [63:0] ldr_DDRAM_DIN;

ddram_phy u_ldr_ddram (
	.clk(clk_sys), .reset(~pll_locked),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT),
	.DDRAM_ADDR(ldr_DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);

// the granules replayed byte by byte: the QS1000's u7 and, unless a .nvm came first, the EEPROM default
wire ldr_tap = ldr_tap_addr[26:17] == SD_SNDCPU[26:17] || (ldr_tap_addr[26:7] == SD_EEPROM[26:7] && !nvm_seen);

vh_rom_loader u_ldr (
	.clk(clk_sys), .reset(~pll_locked),
	.length({1'b0, SD_GFX} + (mod_byte1[0] ? 28'h1000000 : 28'h0800000)),
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
wire [31:0] dbg_pc, dbg_npc, dbg_sr, dbg_imiss, dbg_dmiss;
wire [26:1] dbg_fill_a;
wire [63:0] dbg_fill_d;
wire        dbg_miss, dbg_miss_ic;
wire [21:4] dbg_miss_line;
wire        dbg_rf_we;
wire [5:0]  dbg_rf_wa;
wire [31:0] dbg_rf_wd;
wire [23:0] dbg_tr_start;
wire [11:0] dbg_tr_idx;
wire [187:0] dbg_tr_q;
wire [12:0] dbg_tr_count;

vh_main u_main (
	.clk(clk_sys), .prst(~pll_locked), .rst(core_reset), .board(board), .family(family), .pause(pause_cpu), .cpu_tick(cpu_tick),
	.vblank_irq(vblank_start), .p1p2(p1p2), .system(sys_in),
	.flip(game_flip), .snd_latch(snd_latch), .snd_latch_wr(snd_latch_wr),
	.ym_wr(ym_wr), .ym_a0(ym_a0), .oki_wr(oki_wr), .snd_wd(snd_wd), .oki_bank(oki_bank),
	.ym_dout(ym_dout), .oki_dout(oki_dout),
	.spr_we(spr_we), .spr_be(spr_be), .spr_addr(spr_addr), .spr_wd(spr_wd), .spr_rd(spr_rd),
	.pal_we(pal_we), .pal_be(pal_be), .pal_addr(pal_addr), .pal_wd(pal_wd), .pal_rd(pal_rd),
	.ee_blank(ee_blank), .ee_load_we(ee_we), .ee_load_addr(ee_wa), .ee_load_data(ee_wd),
	.ee_rd_addr(ioctl_addr[6:1]), .ee_rd_data(ee_rd_data), .ee_written(ee_written),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_g(ldr_active), .dl_gdata(ldl_gdata), .dl_busy(dl_busy),
	.mem_addr(m2_addr), .mem_wrl(m2_wrl), .mem_wrh(m2_wrh), .mem_din(m2_din), .mem_dinx(m2_dinx), .mem_wrx(m2_wrx), .mem_dbl(m2_dbl),
	.mem_req(m2_req), .mem_ack(m2_ack), .mem_dout(m_dout), .mem_doutb(m_doutb),
	.retire(dbg_retire), .retire_pc(dbg_pc), .retire_npc(dbg_npc), .retire_sr(dbg_sr), .st_imiss(dbg_imiss), .st_dmiss(dbg_dmiss),
	.dbg_fill_a(dbg_fill_a), .dbg_fill_d(dbg_fill_d),
	.dbg_miss(dbg_miss), .dbg_miss_ic(dbg_miss_ic), .dbg_miss_line(dbg_miss_line),
	.dbg_rf_we(dbg_rf_we), .dbg_rf_wa(dbg_rf_wa), .dbg_rf_wd(dbg_rf_wd),
	.trace_start(dbg_tr_start), .trace_idx(dbg_tr_idx), .trace_valid(), .trace_rec(),
	.trace_q(dbg_tr_q), .trace_count(dbg_tr_count)
);

// Probes: Vamphalf_stp revision only (DEBUG_ISSP); scripts/read_issp.tcl decodes them.
`ifdef DEBUG_ISSP
reg  [31:0] dbg_ninstr = 0, dbg_dlbytes = 0;
reg  [15:0] dbg_palw = 0;
reg  [7:0]  dbg_frames = 0;
always @(posedge clk_sys) begin
	if (dbg_retire) dbg_ninstr <= dbg_ninstr + 1'd1;
	if (pal_we) dbg_palw <= dbg_palw + 1'd1;
	if (vblank_start) dbg_frames <= dbg_frames + 1'd1;
	if (lb_wr && lb_index == 16'd0) dbg_dlbytes <= dbg_dlbytes + 1'd1;
end
// Instance F: [31:0] instructions retired, [63:32] last retired PC, [79:64] D-misses, [95:80] I-misses,
// [111:96] palette writes, [119:112] frames, [120] rom_loaded, [121] core_reset, [122] board,
// [123] ioctl_download, [124] dl_seen, [125] ldr_active, [126] ldr_done, [127] pll_locked
issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(8)) u_issp_f (
	.clk(clk_sys),
	.probe({pll_locked, ldr_done, ldr_active, dl_seen, ioctl_download, board, core_reset, rom_loaded, dbg_frames, dbg_palw,
	        dbg_imiss[15:0], dbg_dmiss[15:0], dbg_pc, dbg_ninstr}),
	.source()
);
// Instance D: [63:0] the first line fill's second 8 bytes (byte 8 in [63:56]: the reset instruction at
// 0xfffffff8), [89:64] its SDRAM word address, [127:96] bytes downloaded (index 0).
// Source: [1:0] sdram.sv rd_adj, [2] hold the core in reset
wire [7:0] dbg_src_d;
issp_probe #(.INSTANCE_ID("D"), .PROBE_W(128), .SOURCE_W(8)) u_issp_d (
	.clk(clk_sys),
	.probe({dbg_dlbytes, 6'd0, dbg_fill_a, dbg_fill_d}),
	.source(dbg_src_d)
);
// Instance T: the last 256 cache misses since reset, a ring of {I, 13'b0, line [21:4], instructions
// retired before it [31:0]}; the source picks the slot, the probe returns {misses so far [15:0], slot}
reg  [63:0] dbg_log [0:255];
reg  [15:0] dbg_log_n = 0;
reg  [31:0] dbg_log_ni = 0;
reg  [63:0] dbg_log_q;
wire [7:0]  dbg_log_sel;
always @(posedge clk_sys) begin
	if (core_reset) begin dbg_log_n <= 0; dbg_log_ni <= 0; end
	else begin
		if (dbg_retire) dbg_log_ni <= dbg_log_ni + 1'd1;
		if (dbg_miss) begin
			dbg_log[dbg_log_n[7:0]] <= {dbg_miss_ic, 13'd0, dbg_miss_line, dbg_log_ni};
			if (dbg_log_n != 16'hffff) dbg_log_n <= dbg_log_n + 1'd1;
		end
	end
	dbg_log_q <= dbg_log[dbg_log_sel];
end
issp_probe #(.INSTANCE_ID("T"), .PROBE_W(80), .SOURCE_W(8)) u_issp_t (
	.clk(clk_sys), .probe({dbg_log_n, dbg_log_q}), .source(dbg_log_sel)
);
// Instance P: {npc, sr} after each of 256 instructions from instruction 8 * source[15:0] (counted from
// reset); source[23:16] picks the entry. The probe returns {entries filled [8:0], npc, sr}.
reg  [63:0] dbg_pct [0:255];
reg  [8:0]  dbg_pct_n = 0;
reg  [63:0] dbg_pct_q;
wire [23:0] dbg_pct_src;
always @(posedge clk_sys) begin
	if (core_reset) dbg_pct_n <= 0;
	else if (dbg_retire && dbg_log_ni >= {13'd0, dbg_pct_src[15:0], 3'd0} && !dbg_pct_n[8]) begin
		dbg_pct[dbg_pct_n[7:0]] <= {dbg_npc, dbg_sr};
		dbg_pct_n <= dbg_pct_n + 1'd1;
	end
	dbg_pct_q <= dbg_pct[dbg_pct_src[23:16]];
end
issp_probe #(.INSTANCE_ID("P"), .PROBE_W(73), .SOURCE_W(24)) u_issp_p (
	.clk(clk_sys), .probe({dbg_pct_n, dbg_pct_q}), .source(dbg_pct_src)
);
// Instance W: the first 256 writes to one local register slot after reset, {data, instructions
// retired before it [31:0]}; source[5:0] the slot, [15:8] the entry. Probe {writes logged [8:0], entry}.
reg  [63:0] dbg_rfw [0:255];
reg  [8:0]  dbg_rfw_n = 0;
reg  [63:0] dbg_rfw_q;
wire [15:0] dbg_rfw_src;
always @(posedge clk_sys) begin
	if (core_reset) dbg_rfw_n <= 0;
	else if (dbg_rf_we && dbg_rf_wa == dbg_rfw_src[5:0] && !dbg_rfw_n[8]) begin
		dbg_rfw[dbg_rfw_n[7:0]] <= {dbg_rf_wd, dbg_log_ni};
		dbg_rfw_n <= dbg_rfw_n + 1'd1;
	end
	dbg_rfw_q <= dbg_rfw[dbg_rfw_src[15:8]];
end
issp_probe #(.INSTANCE_ID("W"), .PROBE_W(73), .SOURCE_W(16)) u_issp_w (
	.clk(clk_sys), .probe({dbg_rfw_n, dbg_rfw_q}), .source(dbg_rfw_src)
);
// the source comes from the JTAG side: two flops into clk_sys, so the reset it holds releases in one clock
reg [7:0] dbg_src_d1, dbg_src_d2;
always @(posedge clk_sys) begin dbg_src_d1 <= dbg_src_d; dbg_src_d2 <= dbg_src_d1; end
assign dbg_rd_adj = dbg_src_d2[1:0];
assign dbg_hold   = dbg_src_d2[2];
// Instance X: the architectural trace (rtl/debug/vh_trace.sv). Source {start [23:0], entry [11:0]};
// probe {records [12:0], record [187:0]}. scripts/read_trace.py sets the start, resets the core
// through instance D and dumps the buffer.
wire [35:0] dbg_tr_src;
issp_probe #(.INSTANCE_ID("X"), .PROBE_W(201), .SOURCE_W(36)) u_issp_x (
	.clk(clk_sys), .probe({dbg_tr_count, dbg_tr_q}), .source(dbg_tr_src)
);
assign dbg_tr_start = dbg_tr_src[35:12];
assign dbg_tr_idx   = dbg_tr_src[11:0];
// Instance S: frame time. A frame runs vblank to vblank; the CPU is idle while its last retired PC is in
// the game's vblank wait (Mission Craft 0xff46-0xff6a, Wivern Wings 0x10752-0x10778, as sim/sys_tb +idle).
// Busy is the frame's clocks less its idle clocks; a frame with no idle clock is lost (the game's work for
// it did not finish before the next vblank). Probe {frames [15:0], lost [15:0], busiest frame's busy
// clocks [19:0], last frame's busy clocks [19:0], last frame's clocks [19:0]}, since reset or a clear.
// Source [0] clear; a rising edge on [1] presses COIN1, on [2] START1, for 8 frames; [3] holds P1 button 1.
reg  [19:0] spd_fclk = 0, spd_idle = 0, spd_max = 0, spd_lastb = 0, spd_lastf = 0;
reg  [15:0] spd_frames = 0, spd_lost = 0;
reg         spd_in_idle = 0;
reg  [3:0]  spd_coin_n = 0, spd_start_n = 0;
wire [7:0]  spd_src;
reg  [7:0]  spd_src1 = 0, spd_src2 = 0, spd_src3 = 0;
wire [19:0] spd_busy = spd_fclk - spd_idle;
wire [31:0] spd_lo = board ? 32'h10752 : 32'hff46;
wire [31:0] spd_hi = board ? 32'h10778 : 32'hff6a;
always @(posedge clk_sys) begin
	spd_src1 <= spd_src; spd_src2 <= spd_src1; spd_src3 <= spd_src2;
	if (dbg_retire) spd_in_idle <= dbg_pc >= spd_lo && dbg_pc <= spd_hi;
	if (vblank_start) begin
		spd_lastf <= spd_fclk;
		spd_lastb <= spd_busy;
		if (spd_busy > spd_max) spd_max <= spd_busy;
		if (spd_idle == 20'd0) spd_lost <= spd_lost + 1'd1;
		spd_frames <= spd_frames + 1'd1;
		spd_fclk <= 20'd0;
		spd_idle <= 20'd0;
		if (spd_coin_n != 4'd0) spd_coin_n <= spd_coin_n - 4'd1;
		if (spd_start_n != 4'd0) spd_start_n <= spd_start_n - 4'd1;
	end else begin
		if (spd_fclk != 20'hfffff) spd_fclk <= spd_fclk + 1'd1;
		if (spd_in_idle && spd_idle != 20'hfffff) spd_idle <= spd_idle + 1'd1;
	end
	if (spd_src2[1] && !spd_src3[1]) spd_coin_n <= 4'd8;
	if (spd_src2[2] && !spd_src3[2]) spd_start_n <= 4'd8;
	if (spd_src2[0] || core_reset) begin spd_frames <= 0; spd_lost <= 0; spd_max <= 0; end
end
assign dbg_coin  = spd_coin_n != 4'd0;
assign dbg_start = spd_start_n != 4'd0;
assign dbg_b1    = spd_src2[3];
issp_probe #(.INSTANCE_ID("S"), .PROBE_W(92), .SOURCE_W(8)) u_issp_s (
	.clk(clk_sys), .probe({spd_frames, spd_lost, spd_max, spd_lastb, spd_lastf}), .source(spd_src)
);
`else
assign dbg_tr_start = 24'hffffff;      // never armed; the outputs are unused, so it is removed
assign dbg_tr_idx   = 12'd0;
assign dbg_rd_adj = 2'd0;
assign dbg_hold   = 1'b0;
assign dbg_coin   = 1'b0;
assign dbg_start  = 1'b0;
assign dbg_b1     = 1'b0;
`endif

wire        gfx_req, gfx_rdy, gfx_dv;
wire [23:0] gfx_addr;
wire [31:0] gfx_data;
wire [7:0]  core_r, core_g, core_b;
wire        core_hs, core_vs, core_hb, core_vb, core_ce;

// The OSD's Flip Screen and the game's flip are one path, through the engine, for HDMI and analog.
vh_video u_video (
	.clk(clk_sys), .rst(~pll_locked | ioctl_download | ldr_active), .code_mask(mod_byte1[0] ? 16'hffff : 16'h7fff), .palshift(f_suplup),
	.spr_we(spr_we), .spr_be(spr_be), .spr_addr(spr_addr), .spr_wd(spr_wd), .spr_rd(spr_rd),
	.pal_we(pal_we), .pal_be(pal_be), .pal_addr(pal_addr), .pal_wd(pal_wd), .pal_rd(pal_rd),
	.flip(game_flip ^ status[65]),
	.gfx_req(gfx_req), .gfx_rdy(gfx_rdy), .gfx_addr(gfx_addr), .gfx_dv(gfx_dv), .gfx_data(gfx_data),
	.ce_pix(core_ce), .vid_r(core_r), .vid_g(core_g), .vid_b(core_b),
	.hblank(core_hb), .vblank(core_vb), .hsync(core_hs), .vsync(core_vs), .hpos(), .vpos(),
	.frame_start(), .vblank_start(vblank_start),
	.dbg_overrun(), .dbg_maxbusy()
);

wire [26:1] m0_addr;
wire        m0_req, m0_ack;

vh_gfxport #(.GFX_BASE(SD_GFX)) u_gfx (
	.clk(clk_sys), .prst(~pll_locked), .gfx_req(gfx_req), .gfx_rdy(gfx_rdy), .gfx_addr(gfx_addr), .gfx_dv(gfx_dv), .gfx_data(gfx_data),
	.mem_addr(m0_addr), .mem_req(m0_req), .mem_ack(m0_ack), .mem_dout(m_dout), .mem_doutb(m_doutb)
);

// The sound boards, one per set (snd_qs), the other held in reset; both read SDRAM port 1 at SD_SAMPLES.
// The QS1000's u7 is caught on its way to SDRAM.
wire        snd_dl = lb_wr && lb_index == 16'd0 && lb_addr[26:17] == SD_SNDCPU[26:17];
wire [26:1] m1_addr, qs_addr, yo_addr;
wire        m1_req, m1_ack, qs_req, yo_req;
wire [63:0] m1_dout, m1_doutb;
wire signed [15:0] qs_l, qs_r, yo_l, yo_r;
assign m1_addr = snd_qs ? qs_addr : yo_addr;
assign m1_req  = snd_qs ? qs_req : yo_req;

vh_qs1000 u_snd (
	.clk(clk_sys), .rst(core_reset | ~snd_qs),
	.dl_we(snd_dl), .dl_addr(lb_addr[16:0]), .dl_data(lb_dout),
	.latch_wr(snd_latch_wr), .latch_d(snd_latch), .bal_pcb(1'b1),     // the PCB recording's balance (MAME_KLUDGES.md, Sound)
	.sd_addr(qs_addr), .sd_req(qs_req), .sd_ack(m1_ack), .sd_dout(m1_dout), .sd_doutb(m1_doutb),
	.out_l(qs_l), .out_r(qs_r),
	.dbg_drops(), .dbg_stalls()
);

vh_ymoki u_ymoki (
	.clk(clk_sys), .rst(core_reset | snd_qs), .xtal14(f_suplup), .dl(ioctl_download | ldr_active),
	.ym_wr(ym_wr), .ym_a0(ym_a0), .ym_din(snd_wd), .ym_dout(ym_dout),
	.oki_wr(oki_wr), .oki_din(snd_wd), .oki_dout(oki_dout), .bank(oki_bank), .banked(family == 5'd4),
	.sd_addr(yo_addr), .sd_req(yo_req), .sd_ack(m1_ack), .sd_dout(m1_dout),
	.out_l(yo_l), .out_r(yo_r)
);

sdram #(.RFS_INTERVAL(10'd218)) u_sdram (
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(), .SDRAM_CKE(SDRAM_CKE),
	.init(~pll_locked), .clk(clk_sys), .rd_adj(dbg_rd_adj),
	.addr0(m0_addr), .wrl0(1'b0), .wrh0(1'b0), .din0(16'd0), .dout0(m_dout), .req0(m0_req), .ack0(m0_ack),
	.dbl0(1'b1), .dout0b(m_doutb),
	.addr1(m1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1(16'd0), .dout1(m1_dout), .req1(m1_req), .ack1(m1_ack),
	.dbl1(snd_qs), .dout1b(m1_doutb),
	.addr2(m2_addr), .wrl2(m2_wrl), .wrh2(m2_wrh), .din2(m2_din), .din2x(m2_dinx), .wrx2(m2_wrx), .dout2(), .req2(m2_req), .ack2(m2_ack),
	.dbl2(m2_dbl), .dout2b()
);

///////////////////////   VIDEO   ////////////////////////////////

wire vga_de_raw;
wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb, crt_on, crt_ce;

vh_crt u_crt (
	.clk(clk_sys), .ce(core_ce),
	.adjust(status[94] & ~forced_scandoubler),
	.hsize_idx(status[99:95]), .hpos_idx(status[106:100]), .vshift_idx(status[112:107]),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .hb_in(core_hb), .vb_in(core_vb),
	.active(crt_on), .ce_out(crt_ce),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video
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
	.ARX((!ar) ? base_arx : (ar - 1'd1)),
	.ARY((!ar) ? base_ary : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[68:66])
);

// HDMI rotation: screen_rotate_two writes the output into DDR3 for the HPS framebuffer; the analog
// output keeps the native raster. Its flip is not used: Flip Screen goes through the engine.
// While the fast load copies, the copy has DDR3 and the rotator sees it busy (it has no reset and
// counts a write as taken whenever BUSY is low: Arcade-Seta_MiSTer, Seta.sv).
wire        rot_DDRAM_CLK, rot_DDRAM_WE, rot_DDRAM_RD;
wire [7:0]  rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;
assign DDRAM_CLK      = ldr_active ? clk_sys            : rot_DDRAM_CLK;
assign DDRAM_BURSTCNT = ldr_active ? ldr_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_active ? ldr_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_active ? ldr_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_active ? ldr_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_active ? ldr_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_active ? ldr_DDRAM_RD       : rot_DDRAM_RD;
screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),

	.rotate_ccw(rotate_ccw),
	.no_rotate(~rotate_en),
	.flip(1'b0),
	.two_screen(1'b0),
	.video_rotated(),

	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),

	.DDRAM_CLK(rot_DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY | ldr_active),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT),
	.DDRAM_ADDR(rot_DDRAM_ADDR),
	.DDRAM_DIN(rot_DDRAM_DIN),
	.DDRAM_BE(rot_DDRAM_BE),
	.DDRAM_WE(rot_DDRAM_WE),
	.DDRAM_RD(rot_DDRAM_RD)
);

endmodule
