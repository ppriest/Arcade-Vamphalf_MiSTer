// Standalone synthesis wrapper for the E1 CPU: all ports straight to pins
// (virtual in the .qsf), so area and Fmax are the CPU's own.
module e1_synth_top (
	input clk, input reset, input pause, input tick,
	input [6:0] irq_in, output [6:0] irq_ack,
	output bus_req, output bus_wr, output bus_io,
	output [31:0] bus_addr, output [3:0] bus_be, output [31:0] bus_wdata,
	input bus_ack, input [31:0] bus_rdata,
	output if_req, output [31:3] if_addr, input if_ack, input [63:0] if_data,
	output retire, output [31:0] retire_pc, output [31:0] retire_npc, output [31:0] retire_sr
);
e1_cpu cpu (.cen(1'b1), .tick2(1'b0), .dbg_rf_we(), .dbg_rf_wa(), .dbg_rf_wd(), .*);
endmodule
