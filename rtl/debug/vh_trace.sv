// Architectural trace of the E1 for board-against-bench comparison (scripts/trace_compare.py).
//
// From the first retirement at or after instruction `start` (counted from reset), every clock in which
// the CPU retires an instruction, writes its local register file, or completes a bus transfer is
// recorded, 4096 records, then recording stops. sim/sys_tb prints the same records (rec_valid, rec), so
// the two streams come from one piece of RTL.
//
// Record, 188 bits, MSB first:
//   [187:176] clock count, low 12 bits (informational: board and bench timing differ)
//   [175] retire  [174] register-file write  [173] bus transfer  [172] bus write  [171] I/O  [170] 0 (instruction
//   fetches have their own port and are not recorded)
//   [169:166] byte enables   [165:160] register slot
//   [159:128] PC after the instruction   [127:96] SR after it   [95:64] register value
//   [63:32] bus address   [31:0] bus data (written, or read back)

module vh_trace (
	input              clk,
	input              rst,
	input      [23:0]  start,

	input              retire,
	input      [31:0]  npc,
	input      [31:0]  sr,
	input              rf_we,
	input      [5:0]   rf_wa,
	input      [31:0]  rf_wd,
	input              bus_req,
	input              bus_ack,
	input              bus_wr,
	input              bus_io,
	input      [3:0]   bus_be,
	input      [31:0]  bus_addr,
	input      [31:0]  bus_wdata,
	input      [31:0]  bus_rdata,

	output             rec_valid,
	output     [187:0] rec,

	input      [11:0]  rd_idx,
	output reg [187:0] rd_q,
	output reg [12:0]  count
);

reg  [11:0] cyc;
reg  [31:0] nret;
wire        armed = nret >= {8'd0, start};
wire        f_bus = bus_req && bus_ack;

assign rec_valid = armed && (retire || rf_we || f_bus);
assign rec = {cyc, retire, rf_we, f_bus, bus_wr, bus_io, 1'b0, bus_be, rf_wa,
              npc, sr, rf_wd, bus_addr, bus_wr ? bus_wdata : bus_rdata};

(* ramstyle = "M10K" *) reg [187:0] mem [0:4095];

always @(posedge clk) begin
	if (rst) begin
		cyc <= 12'd0;
		nret <= 32'd0;
		count <= 13'd0;
	end else begin
		cyc <= cyc + 12'd1;
		if (retire) nret <= nret + 32'd1;
		if (rec_valid && !count[12]) count <= count + 13'd1;
	end
end

always @(posedge clk) begin
	if (!rst && rec_valid && !count[12]) mem[count[11:0]] <= rec;
	rd_q <= mem[rd_idx];
end

endmodule
