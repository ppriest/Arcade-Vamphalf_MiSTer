// Standalone synthesis wrapper for the E1 CPU: all ports straight to pins
// (virtual in the .qsf), so area and Fmax are the CPU's own.
module e1_synth_top (
	input clk, input reset, input pause, input tick,
	input [6:0] irq_in, output [6:0] irq_ack,
	output bus_req, output bus_wr, output bus_io, output bus_ifetch,
	output [31:0] bus_addr, output [3:0] bus_be, output [31:0] bus_wdata,
	input bus_ack, input [31:0] bus_rdata,
	output retire, output [31:0] retire_pc, output [31:0] retire_npc, output [31:0] retire_sr
);
e1_cpu cpu (.cen(1'b1), .*);
endmodule
