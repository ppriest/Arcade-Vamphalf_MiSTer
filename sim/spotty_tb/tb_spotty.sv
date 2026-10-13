// Bench top for spotty's sound board (rtl/sound/lm_spotty.sv): its ports, SDRAM port 1 as a fixed-latency
// model served by main.cpp, and the MCU's state for the compare with the MAME trace.
module tb_spotty (
	input               clk,
	input               rst,
	input               dl_we,
	input       [11:0]  dl_addr,
	input       [7:0]   dl_data,
	input               latch_wr,
	input       [7:0]   latch_d,
	output      [26:1]  sd_addr,
	output              sd_req,
	input               sd_ack,
	input       [63:0]  sd_dout,
	output signed [15:0] out,
	output              o_ni,
	output              o_irq_taken,
	output      [15:0]  o_pc,
	output      [7:0]   o_a,
	output      [7:0]   o_b,
	output      [7:0]   o_psw,
	output      [7:0]   o_sp,
	output      [15:0]  o_dptr,
	output      [7:0]   o_ie,
	output      [7:0]   o_ip,
	output      [7:0]   o_tcon,
	output      [7:0]   o_tmod,
	output      [7:0]   o_tl0,
	output      [7:0]   o_th0,
	output      [7:0]   o_tl1,
	output      [7:0]   o_th1,
	output      [7:0]   o_p1,
	output      [7:0]   o_p3,
	output              o_oki_wr,
	output      [7:0]   o_oki_din,
	output   [2047:0]   o_iram
);
lm_spotty #(.SAMPLES_BASE(27'h400000)) u_snd (
	.clk(clk), .rst(rst), .dl(1'b0),
	.dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data),
	.latch_wr(latch_wr), .latch_d(latch_d),
	.sd_addr(sd_addr), .sd_req(sd_req), .sd_ack(sd_ack), .sd_dout(sd_dout),
	.out(out)
);
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
assign o_p1   = u_snd.p1_o;
assign o_p3   = u_snd.p3_latch;
assign o_oki_wr  = u_snd.oki_wr;
assign o_oki_din = u_snd.oki_din;
reg irq_l = 1'b0;
always @(posedge clk) if (u_snd.mcen) irq_l <= u_snd.u_mcu.u_ctrl.irq_take;
assign o_irq_taken = irq_l;
generate for (genvar k = 0; k < 256; k = k + 1) begin : g_iram
	assign o_iram[8*k +: 8] = u_snd.u_iram.mem[k];
end endgenerate
endmodule
