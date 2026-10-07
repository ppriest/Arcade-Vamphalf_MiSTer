// Bench top for World Adventure's protection (rtl/vh_prot_wa.sv): ports straight through.
module tb_prot_wa (
	input         clk,
	input         rst,
	input         wr,
	input  [15:0] wd,
	input         rd,
	output [15:0] rdata
);
vh_prot_wa u (.*);
endmodule
