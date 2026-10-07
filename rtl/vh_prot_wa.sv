// World Adventure's FPGA protection as MAME models it (worldadv_fpga_prot_device, vamphalf_prot.cpp:318-419):
// 33 seed bits written one per access (bit 0), restarted by 0xffff; at the 33rd the seed is looked up among the
// seven MAME has seen, the device arms, and eight reads return the result's bits 7..0 as 0xffff or 0, then 0.
// An unknown seed arms with the previous result, as MAME leaves m_retval unchanged.
module vh_prot_wa (
	input             clk,
	input             rst,
	input             wr,
	input      [15:0] wd,
	input             rd,
	output     [15:0] rdata
);

reg [32:0] seed;
reg [5:0]  widx;
reg [2:0]  ridx;
reg        armed;
reg [7:0]  retval;

wire [32:0] seed_n = {seed[31:0], wd[0]};
reg  [8:0]  look;                  // {found, value}
always @* begin
	case (seed_n)
		33'h18c97f6d7: look = {1'b1, 8'ha7};    // about 0:30
		33'h0baa9edf7: look = {1'b1, 8'h6d};    // 0:45
		33'h038f839bf: look = {1'b1, 8'h20};    // 1:00
		33'h110037f0f: look = {1'b1, 8'h58};    // 1:15
		33'h10aace5bd: look = {1'b1, 8'h55};    // 1:30
		33'h0f8cecc8f: look = {1'b1, 8'h74};    // 1:45
		33'h19678b311: look = {1'b1, 8'hf5};    // 2:00
		default:       look = {1'b0, 8'h00};
	endcase
end

assign rdata = (armed && retval[3'd7 - ridx]) ? 16'hffff : 16'h0000;

always @(posedge clk) begin
	if (rst) begin
		seed <= 33'd0; widx <= 6'd0; ridx <= 3'd0; armed <= 1'b0; retval <= 8'd0;
	end else begin
		if (wr) begin
			if (wd == 16'hffff) begin
				widx <= 6'd0;
				seed <= 33'd0;
			end else begin
				seed <= seed_n;
				widx <= widx + 6'd1;
				if (widx == 6'd32) begin
					armed <= 1'b1;
					ridx <= 3'd0;
					if (look[8]) retval <= look[7:0];
				end
			end
		end
		if (rd && armed) begin
			ridx <= ridx + 3'd1;
			if (ridx == 3'd7) armed <= 1'b0;
		end
	end
end

endmodule
