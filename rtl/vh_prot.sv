// The two boards' FPGA protection, as MAME models it (vamphalf_prot.cpp): a seed written one value per
// write, committed by 0xffff, looked up in a table of the seeds MAME has seen; an unknown seed gives 0.
//
// The seed is not stored. A write at position k clears, for every table entry, a "still matches" flag
// when the value differs from the entry's value k. At the commit an entry matches when its flag is set
// and at least as many values were written as the entry is long: MAME compares the first seed_size
// values of a seed array it clears at every commit, and no seed value in the tables is 0, so a short
// seed does not match there either. The first matching entry wins, as in prot_value_check.
//
// Mission Craft (misncrft_fpga_prot_device): byte seeds; ports 0x0d0 (16-byte table) and 0x1a0
// (8-byte table) share the seed, the index and the result. A read at either gives bit 7-idx of the
// result as 0xffff or 0 and advances idx (0 from idx 8 on: MAME shifts by a negative count there,
// which x86 takes modulo 32).
// Wivern Wings (wyvernwg_fpga_prot_device): 16-word seeds at 0x1800; a read returns the result.

module vh_prot (
	input             clk,
	input             rst,
	input             board,          // 0 Mission Craft, 1 Wivern Wings

	input             wr,             // a seed write, with its value and (Mission Craft) its table
	input             tab16,
	input      [15:0] wd,
	input             rd,             // Mission Craft: a read (advances the bit index)
	output     [15:0] rdata
);

`include "vh_prot_tables.svh"

reg  [7:0]  retval;
reg  [5:0]  idx;
reg         armed;
reg  [1:0]  ok16;
reg  [6:0]  ok8;
reg  [10:0] okw;

// per entry: its result, and its value at the current index
reg  [7:0]  r16 [0:1], r8 [0:6], rw [0:10];
reg  [7:0]  v16 [0:1], v8 [0:6];
reg  [15:0] vw [0:10];
reg  [135:0] e16;
reg  [71:0]  e8;
reg  [263:0] ew;
integer i;
always @* begin
	for (i = 0; i < 2; i = i + 1) begin
		e16 = vh_prot_t16(i[0]);
		r16[i] = e16[7:0];
		v16[i] = e16[135 - 8*idx[3:0] -: 8];
	end
	for (i = 0; i < 7; i = i + 1) begin
		e8 = vh_prot_t8(i[2:0]);
		r8[i] = e8[7:0];
		v8[i] = e8[71 - 8*idx[2:0] -: 8];
	end
	for (i = 0; i < 11; i = i + 1) begin
		ew = vh_prot_tw(i[3:0]);
		rw[i] = ew[7:0];
		vw[i] = ew[263 - 16*idx[3:0] -: 16];
	end
end

reg  [7:0]  hit_val;
always @* begin
	hit_val = 8'h00;
	if (!board) begin
		if (tab16) begin
			for (i = 1; i >= 0; i = i - 1)
				if (ok16[i] && idx >= 6'd16) hit_val = r16[i];
		end else begin
			for (i = 6; i >= 0; i = i - 1)
				if (ok8[i] && idx >= 6'd8) hit_val = r8[i];
		end
	end else begin
		for (i = 10; i >= 0; i = i - 1)
			if (okw[i] && idx >= 6'd16) hit_val = rw[i];
	end
end

wire [7:0] rbit_sh = retval << idx[2:0];
assign rdata = !board ? ((idx < 6'd8 && rbit_sh[7]) ? 16'hffff : 16'h0000) : {8'h00, retval};

integer j;
always @(posedge clk) begin
	if (rst) begin
		retval <= 8'hff;
		idx    <= 6'd0;
		armed  <= 1'b0;
		ok16   <= '1;
		ok8    <= '1;
		okw    <= '1;
	end else if (wr) begin
		if (wd == 16'hffff) begin
			idx <= 6'd0;
			if (armed) retval <= hit_val;
			armed <= 1'b0;
			ok16  <= '1;
			ok8   <= '1;
			okw   <= '1;
		end else begin
			armed <= 1'b1;
			if (idx != 6'd63) idx <= idx + 6'd1;
			for (j = 0; j < 2; j = j + 1)
				if (idx < 6'd16 && wd[7:0] != v16[j]) ok16[j] <= 1'b0;
			for (j = 0; j < 7; j = j + 1)
				if (idx < 6'd8 && wd[7:0] != v8[j]) ok8[j] <= 1'b0;
			for (j = 0; j < 11; j = j + 1)
				if (idx < 6'd16 && wd != vw[j]) okw[j] <= 1'b0;
		end
	end else if (rd && !board) begin
		if (idx != 6'd63) idx <= idx + 6'd1;
	end
end

endmodule
