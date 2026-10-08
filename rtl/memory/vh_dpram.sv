// One clock, two ports: A reads and writes (byte enables, clock enable), B reads every clock.
//
// Synthesis instantiates altsyncram in BIDIR_DUAL_PORT: inferred from the behavioural model, Quartus 17
// builds one simple-dual-port copy per reader (242 M10K for the 128 KB of palette and sprite RAM)
// (LESSONS_LEARNED, "Driving a dual-port RAM's second read port can silently REPLICATE the array").
// The benches run the behavioural model (Quartus synthesis defines ALTERA_RESERVED_QIS).
//
// Port A's read during its own write is unspecified (altsyncram returns the new data, the model the
// old); no user reads A in a write cycle.
module vh_dpram #(
	parameter AW  = 14,
	parameter DW  = 32,
	parameter NBE = 4                  // DW / 8
) (
	input               clk,
	input               a_ce,          // port A address, data and write register enable
	input   [NBE-1:0]   a_we,
	input   [AW-1:0]    a_addr,
	input   [DW-1:0]    a_wd,
	output  [DW-1:0]    a_rd,
	input   [AW-1:0]    b_addr,
	output  [DW-1:0]    b_rd
);

`ifndef ALTERA_RESERVED_QIS
reg [DW-1:0] mem [0:(1 << AW) - 1];
reg [DW-1:0] qa, qb;
integer i;
always @(posedge clk) if (a_ce) begin
	for (i = 0; i < NBE; i = i + 1)
		if (a_we[i]) mem[a_addr][8*i +: 8] <= a_wd[8*i +: 8];
	qa <= mem[a_addr];
end
always @(posedge clk) qb <= mem[b_addr];
assign a_rd = qa;
assign b_rd = qb;
`else
altsyncram #(
	.operation_mode("BIDIR_DUAL_PORT"),
	.ram_block_type("M10K"),
	.intended_device_family("Cyclone V"),
	.lpm_type("altsyncram"),
	.numwords_a(1 << AW), .widthad_a(AW), .width_a(DW),
	.numwords_b(1 << AW), .widthad_b(AW), .width_b(DW),
	.width_byteena_a(NBE), .byte_size(8),
	.width_byteena_b(1),
	.outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
	.address_reg_b("CLOCK1"), .indata_reg_b("CLOCK1"), .wrcontrol_wraddress_reg_b("CLOCK1"),
	.clock_enable_input_a("NORMAL"), .clock_enable_output_a("BYPASS"),
	.clock_enable_input_b("BYPASS"), .clock_enable_output_b("BYPASS"),
	.outdata_aclr_a("NONE"), .outdata_aclr_b("NONE"),
	.read_during_write_mode_mixed_ports("DONT_CARE"),
	.read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
	.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
	.power_up_uninitialized("FALSE")
) u_ram (
	.clock0(clk), .clocken0(a_ce), .address_a(a_addr), .data_a(a_wd), .wren_a(|a_we), .byteena_a(a_we), .q_a(a_rd),
	.clock1(clk), .clocken1(1'b1), .address_b(b_addr), .data_b({DW{1'b0}}), .wren_b(1'b0), .q_b(b_rd),
	.aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0), .byteena_b(1'b1),
	.clocken2(1'b1), .clocken3(1'b1), .rden_a(1'b1), .rden_b(1'b1), .eccstatus()
);
`endif

endmodule
