// E1 local register file: 64 x 32, one write port, five asynchronous read ports.
// Each read port is its own copy of the array so Quartus maps each to MLAB.
module e1_regram (
	input             clk,
	input             we,
	input      [5:0]  wa,
	input      [31:0] wd,
	input      [5:0]  ra0, ra1, ra2, ra3, ra4,
	output     [31:0] rd0, rd1, rd2, rd3, rd4
);

(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] m0 [0:63];
(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] m1 [0:63];
(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] m2 [0:63];
(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] m3 [0:63];
(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] m4 [0:63];

integer i;
initial for (i = 0; i < 64; i = i + 1) begin
	m0[i] = 32'd0; m1[i] = 32'd0; m2[i] = 32'd0; m3[i] = 32'd0; m4[i] = 32'd0;
end

always @(posedge clk) if (we) begin
	m0[wa] <= wd; m1[wa] <= wd; m2[wa] <= wd; m3[wa] <= wd; m4[wa] <= wd;
end

assign rd0 = m0[ra0];
assign rd1 = m1[ra1];
assign rd2 = m2[ra2];
assign rd3 = m3[ra3];
assign rd4 = m4[ra4];

endmodule
