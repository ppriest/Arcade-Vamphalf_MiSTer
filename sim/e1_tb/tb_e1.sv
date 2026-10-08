// Bench top for e1_cpu: exposes the architectural state flat.
module tb_e1 (
	input             clk,
	input             reset,
	input             pause,
	input      [6:0]  irq_in,
	output     [6:0]  irq_ack,
	output            bus_req,
	output            bus_wr,
	output            bus_io,
	output     [31:0] bus_addr,
	output     [3:0]  bus_be,
	output     [31:0] bus_wdata,
	input             bus_ack,
	input      [31:0] bus_rdata,
	output            if_req,
	output     [31:3] if_addr,
	input             if_ack,
	input      [63:0] if_data,
	output            retire,
	output     [31:0] retire_pc,
	output     [31:0] o_pc,
	output     [31:0] o_sr,
	output [1023:0]   o_g,
	output [2047:0]   o_l,
	output [4:0]      o_state,
	output [2:0]      o_wq,
	output [31:0]     o_npc,
	output [31:0]     o_nsr
);

e1_cpu cpu (
	.clk(clk), .reset(reset), .cen(1'b1),
	.bus_req(bus_req), .bus_wr(bus_wr), .bus_io(bus_io),
	.bus_addr(bus_addr), .bus_be(bus_be), .bus_wdata(bus_wdata),
	.bus_ack(bus_ack), .bus_rdata(bus_rdata),
	.if_req(if_req), .if_addr(if_addr), .if_ack(if_ack), .if_data(if_data),
	.irq_in(irq_in), .irq_ack(irq_ack), .pause(pause), .tick(1'b0),
	.retire(retire), .retire_pc(retire_pc)
);

assign o_pc = cpu.pc;
assign o_sr = cpu.sr;
assign o_state = cpu.state;
assign o_wq = cpu.wq_cnt;
assign o_npc = cpu.retire_npc;
assign o_nsr = cpu.retire_sr;
genvar gi;
generate
	for (gi = 0; gi < 32; gi = gi + 1) begin : g
		assign o_g[gi*32 +: 32] = cpu.G[gi];
	end
	for (gi = 0; gi < 64; gi = gi + 1) begin : l
		assign o_l[gi*32 +: 32] = (cpu.l_we_r && cpu.l_wa_r == gi) ? cpu.l_wd_r : cpu.rf.m0[gi];
	end
endgenerate

endmodule
