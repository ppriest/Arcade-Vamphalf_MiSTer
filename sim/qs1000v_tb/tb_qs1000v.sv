// Bench top for the QS1000 voice engine (rtl/qs1000/vh_qs1000_voice.sv): ports straight through.
module tb_qs1000v (
	input              clk,
	input              rst,
	input              wr,
	input       [4:0]  wr_off,
	input       [7:0]  wr_data,
	input              tick,
	input              bal_pcb,
	output             rom_req,
	output      [19:0] rom_line,
	input              rom_ack,
	input      [127:0] rom_data,
	output             mix_valid,
	output signed [31:0] mix_l,
	output signed [31:0] mix_r,
	output signed [15:0] out_l,
	output signed [15:0] out_r,
	output      [15:0] dbg_drops,
	output      [15:0] dbg_stalls
);
vh_qs1000_voice u_v (.*);
endmodule
