// Bench top for the QS1000's 8052 firmware on JT8051 (docs/QS1000_TRACE_FORMAT.md).
//
// Memories follow the board as MAME has it (qs1000.cpp, vamphalf.cpp):
//   program   0x0000-0x7fff  u7 image (+rom=<file>, 128 KB, only the first 32 KB is addressable)
//   external  0x0000-0x00ff  RAM
//             0x0100-0xffff  u7 bank (P3 latch bits 2:0): u7[(bank*0x7f00 + addr) mod 128 KB]
//             0x0200-0x0211  also written to the wavetable registers (ignored here; the engine is
//                            not modelled, the trace compare covers the writes)
// Internal RAM is 256 bytes in the model; CORE selects which CPU drives it:
//   CORE=0  jt8051 as in jtcores (7-bit RAM address: 128 bytes reachable)
//   CORE=1  jt8052 (rtl/qs1000/jt8052): the same core with an 8-bit RAM address for indirect
//           accesses, and Timer 2
//   CORE=2  the core's own vh_qs1000_mcu (rtl/qs1000/vh_qs1000.sv): jt8052 with block-RAM memories
//           and the enable of the board (3 in 7 clocks); u7 goes in through its download port while
//           o_ready is low, and main.cpp holds reset until then
// main.cpp supplies port pins and INT1 from the MAME trace and checks the state after every
// instruction.
module tb_qs1000 #(parameter CORE=0) (
	input             clk,
	input             rst,
	input             int1n,
	input      [7:0]  p0_i,
	input      [7:0]  p1_i,
	input      [7:0]  p2_i,
	input      [7:0]  p3_i,
	output            o_cen,
	output            o_ready,
	output            o_ni,
	output            o_irq_taken,
	output reg [31:0] o_x_cnt,
	output reg        o_x_wr,
	output reg [15:0] o_x_addr,
	output reg [7:0]  o_x_data,
	output     [15:0] o_pc,
	output     [7:0]  o_a,
	output     [7:0]  o_b,
	output     [7:0]  o_psw,
	output     [7:0]  o_sp,
	output     [15:0] o_dptr,
	output     [7:0]  o_ie,
	output     [7:0]  o_ip,
	output     [7:0]  o_tcon,
	output     [7:0]  o_tmod,
	output     [7:0]  o_tl0,
	output     [7:0]  o_th0,
	output     [7:0]  o_tl1,
	output     [7:0]  o_th1,
	output     [7:0]  o_scon,
	output            o_ram_we,
	output     [7:0]  o_ram_addr,
	output     [7:0]  o_ram_dout,
	output     [7:0]  o_p0,
	output     [7:0]  o_p1,
	output     [7:0]  o_p2,
	output     [7:0]  o_p3,
	output     [7:0]  o_t2con,
	output     [15:0] o_tl2,
	output     [15:0] o_rcap2,
	output  [2047:0]  o_iram
);

reg  cen = 1'b0;
reg  [7:0] rom   [0:32767];
reg  [7:0] u7    [0:131071];
reg  [7:0] iram  [0:255];
reg  [7:0] xram  [0:255];
reg  [7:0] rom_din = 8'd0, ram_din = 8'd0;
wire [7:0] x_din;
wire [7:0] p0_o, p1_o, p2_o, p3_o, ram_dout, x_dout;
wire [15:0] rom_addr, x_addr;
wire [7:0] ram_addr;
wire ram_we, x_wr, x_acc;
integer i;
reg [8*256-1:0] romfile;

assign o_cen = cen;

initial begin
	for (i = 0; i < 32768; i = i + 1) rom[i] = 8'hff;
	for (i = 0; i < 131072; i = i + 1) u7[i] = 8'hff;
	for (i = 0; i < 256; i = i + 1) begin iram[i] = 8'd0; xram[i] = 8'd0; end
	if ($value$plusargs("rom=%s", romfile)) $readmemh(romfile, u7);
	for (i = 0; i < 32768; i = i + 1) rom[i] = u7[i];
end

reg [2:0] cacc = 3'd0;
always @(posedge clk)
	if (CORE != 2) cen <= rst ? 1'b0 : ~cen;
	else if (rst) begin cen <= 1'b0; cacc <= 3'd0; end
	else if (cacc >= 3'd4) begin cen <= 1'b1; cacc <= cacc - 3'd4; end
	else begin cen <= 1'b0; cacc <= cacc + 3'd3; end

// CORE=2: u7 into the core's RAM through the download port
reg [17:0] dl_n = 18'd0;
always @(posedge clk) if (CORE == 2 && !dl_n[17]) dl_n <= dl_n + 18'd1;
assign o_ready = CORE != 2 || dl_n[17];

wire [2:0] bank;
wire [7:0] x_din_c;

always @(posedge clk) if (cen) begin
	rom_din <= rom_addr < 16'h8000 ? rom[rom_addr[14:0]] : 8'hff;
	ram_din <= iram[ram_addr];
	if (ram_we) iram[ram_addr] <= ram_dout;
	if (x_wr && x_addr < 16'h100) xram[x_addr[7:0]] <= x_dout;
end

assign x_din_c = x_addr < 16'h100 ? xram[x_addr[7:0]] :
                 u7[(bank * 17'h7f00 + {1'b0, x_addr}) & 17'h1ffff];

// one event per cen with x_acc; the bench compares it with the trace's X row
always @(posedge clk) begin
	if (rst) o_x_cnt <= 0;
	else if (cen && x_acc) begin
		o_x_cnt  <= o_x_cnt + 1'd1;
		o_x_wr   <= x_wr;
		o_x_addr <= x_addr;
		o_x_data <= x_wr ? x_dout : (CORE == 2 ? x_din : x_din_c);
	end
end

generate for (genvar k = 0; k < 256; k = k + 1) begin : g_iram
	if (CORE == 2) begin : g2
		assign o_iram[8*k +: 8] = g_core.u_snd.u_iram.mem[k];
	end else begin : g01
		assign o_iram[8*k +: 8] = iram[k];
	end
end endgenerate

wire irq_take_l;

generate if (CORE == 0) begin : g_core
	assign ram_addr[7] = 1'b0;
	jt8051 u_mcu(
		.rst, .clk, .cen,
		.int0n(1'b1), .int1n,
		.p0_i, .p1_i, .p2_i, .p3_i,
		.p0_o, .p1_o, .p2_o, .p3_o,
		.rom_data(rom_din), .rom_addr,
		.ram_din, .ram_dout, .ram_addr(ram_addr[6:0]), .ram_we,
		.x_din(x_din_c), .x_dout, .x_addr, .x_wr, .x_acc
	);
	assign o_ni   = u_mcu.next_instruction;
	assign o_pc   = u_mcu.pc;
	assign o_a    = u_mcu.a;
	assign o_b    = u_mcu.b;
	assign o_psw  = u_mcu.psw;
	assign o_sp   = u_mcu.sp;
	assign o_dptr = u_mcu.dptr;
	assign o_ie   = u_mcu.u_periph.ie;
	assign o_ip   = u_mcu.u_periph.ip;
	assign o_tcon = u_mcu.u_periph.tcon;
	assign o_tmod = u_mcu.u_periph.tmod;
	assign o_tl0  = u_mcu.u_periph.tl0;
	assign o_th0  = u_mcu.u_periph.th0;
	assign o_tl1  = u_mcu.u_periph.tl1;
	assign o_th1  = u_mcu.u_periph.th1;
	assign o_scon = u_mcu.u_periph.scon;
	assign bank   = u_mcu.u_periph.p3[2:0];
	assign o_t2con = 8'd0;
	assign o_tl2   = 16'd0;
	assign o_rcap2 = 16'd0;
	reg irq_l = 1'b0;
	always @(posedge clk) if (cen) irq_l <= u_mcu.u_ctrl.irq_take;
	assign irq_take_l = irq_l;
end
else if (CORE == 1) begin : g_core
	jt8052 u_mcu(
		.rst, .clk, .cen,
		.int0n(1'b1), .int1n,
		.p0_i, .p1_i, .p2_i, .p3_i,
		.p0_o, .p1_o, .p2_o, .p3_o,
		.rom_data(rom_din), .rom_addr,
		.ram_din, .ram_dout, .ram_addr(ram_addr), .ram_we,
		.x_din(x_din_c), .x_dout, .x_addr, .x_wr, .x_acc,
		.p3_we(), .p3_latch()
	);
	assign o_ni   = u_mcu.next_instruction;
	assign o_pc   = u_mcu.pc;
	assign o_a    = u_mcu.a;
	assign o_b    = u_mcu.b;
	assign o_psw  = u_mcu.psw;
	assign o_sp   = u_mcu.sp;
	assign o_dptr = u_mcu.dptr;
	assign o_ie   = u_mcu.u_periph.ie;
	assign o_ip   = u_mcu.u_periph.ip;
	assign o_tcon = u_mcu.u_periph.tcon;
	assign o_tmod = u_mcu.u_periph.tmod;
	assign o_tl0  = u_mcu.u_periph.tl0;
	assign o_th0  = u_mcu.u_periph.th0;
	assign o_tl1  = u_mcu.u_periph.tl1;
	assign o_th1  = u_mcu.u_periph.th1;
	assign o_scon = u_mcu.u_periph.scon;
	assign bank   = u_mcu.u_periph.p3[2:0];
	assign o_t2con = 8'd0;
	assign o_tl2   = 16'd0;
	assign o_rcap2 = 16'd0;
	reg irq_l = 1'b0;
	always @(posedge clk) if (cen) irq_l <= u_mcu.u_ctrl.irq_take;
	assign irq_take_l = irq_l;
end
else begin : g_core
	// the trace supplies P1 and INT1; P0, P2 and the P3 pins are the module's own constants
	vh_qs1000_mcu u_snd (
		.clk, .rst, .cen,
		.dl_we(!dl_n[17]), .dl_addr(dl_n[16:0]), .dl_data(u7[dl_n[16:0]]),
		.p1_i, .int1n,
		.p1_o, .p2_o, .p3_o, .p3_latch(), .p3_we(),
		.x_acc, .x_wr, .x_addr, .x_dout, .x_din
	);
	assign ram_we   = u_snd.ram_we;
	assign ram_addr = u_snd.ram_addr;
	assign ram_dout = u_snd.ram_dout;
	assign o_ni   = u_snd.u_mcu.next_instruction;
	assign o_pc   = u_snd.u_mcu.pc;
	assign o_a    = u_snd.u_mcu.a;
	assign o_b    = u_snd.u_mcu.b;
	assign o_psw  = u_snd.u_mcu.psw;
	assign o_sp   = u_snd.u_mcu.sp;
	assign o_dptr = u_snd.u_mcu.dptr;
	assign o_ie   = u_snd.u_mcu.u_periph.ie;
	assign o_ip   = u_snd.u_mcu.u_periph.ip;
	assign o_tcon = u_snd.u_mcu.u_periph.tcon;
	assign o_tmod = u_snd.u_mcu.u_periph.tmod;
	assign o_tl0  = u_snd.u_mcu.u_periph.tl0;
	assign o_th0  = u_snd.u_mcu.u_periph.th0;
	assign o_tl1  = u_snd.u_mcu.u_periph.tl1;
	assign o_th1  = u_snd.u_mcu.u_periph.th1;
	assign o_scon = u_snd.u_mcu.u_periph.scon;
	assign bank   = u_snd.u_mcu.u_periph.p3[2:0];
	assign o_t2con = 8'd0;
	assign o_tl2   = 16'd0;
	assign o_rcap2 = 16'd0;
	reg irq_l = 1'b0;
	always @(posedge clk) if (cen) irq_l <= u_snd.u_mcu.u_ctrl.irq_take;
	assign irq_take_l = irq_l;
end
endgenerate

assign o_irq_taken = irq_take_l;
assign o_ram_we = ram_we;
assign o_ram_addr = ram_addr;
assign o_ram_dout = ram_dout;
assign o_p0 = p0_o;
assign o_p1 = p1_o;
assign o_p2 = p2_o;
assign o_p3 = p3_o;

endmodule
