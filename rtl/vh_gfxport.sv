// vh_video's graphics-ROM requests onto sdram.sv port 0 (highest priority: the line has a deadline).
//
// A request is a 16-byte sprite row: one double read (two granules from one open row). Requests queue
// four deep; gfx_rdy is low while the queue is full. A completed row is handed back as four 32-bit beats
// on consecutive clocks, byte 0 of the row in [31:24] of the first (SDRAM words hold the even byte in
// [7:0], so the bytes are swapped here). The next request goes out while the beats are emitted.

// Graphics bytes from 16 MB up (boonggab's 28 MB) are at GFXHI_BASE, above the 32 MB line; aoh's whole
// 64 MB is there.

module vh_gfxport #(
	parameter [26:0] GFX_BASE = 27'h0800000,
	parameter [26:0] GFXHI_BASE = 27'h2000000
) (
	input             clk,
	input             prst,           // power-up only (the PLL's lock)

	input             gfx_req,
	output            gfx_rdy,
	input             aoh,
	input      [25:0] gfx_addr,
	output reg        gfx_dv = 1'b0,
	output reg [31:0] gfx_data,

	output reg [26:1] mem_addr,
	output reg        mem_req = 1'b0,
	input             mem_ack,
	input      [63:0] mem_dout,
	input      [63:0] mem_doutb
);

function [63:0] sw64(input [63:0] g);
	sw64 = {g[7:0], g[15:8], g[23:16], g[31:24], g[39:32], g[47:40], g[55:48], g[63:56]};
endfunction

(* ramstyle = "logic" *) reg  [25:4] q [0:3];     // registers: read combinationally
reg  [2:0]  q_wr = 3'd0, q_rd = 3'd0;
wire [2:0]  q_cnt = q_wr - q_rd;
assign gfx_rdy = q_cnt != 3'd4;

reg         busy = 1'b0;
reg  [127:0] row;
reg  [2:0]  beats = 3'd0;

always @(posedge clk) begin
	gfx_dv <= 1'b0;
	if (prst) begin
		q_wr <= 3'd0; q_rd <= 3'd0; busy <= 1'b0; beats <= 3'd0; mem_req <= mem_ack;
	end else begin
		if (gfx_req && gfx_rdy) begin
			q[q_wr[1:0]] <= gfx_addr[25:4];
			q_wr <= q_wr + 3'd1;
		end

		if (!busy) begin
			if (q_cnt != 3'd0) begin
				mem_addr <= {aoh ? GFXHI_BASE[26:4] + {1'b0, q[q_rd[1:0]][25:4]} :
				             (q[q_rd[1:0]][24] ? GFXHI_BASE[26:4] : GFX_BASE[26:4]) + {3'd0, q[q_rd[1:0]][23:4]}, 3'd0};
				mem_req  <= ~mem_req;
				q_rd     <= q_rd + 3'd1;
				busy     <= 1'b1;
			end
		end else if (mem_ack == mem_req) begin
			busy  <= 1'b0;
			row   <= {sw64(mem_dout), sw64(mem_doutb)};
			beats <= 3'd4;
		end

		if (beats != 3'd0 && !(busy && mem_ack == mem_req)) begin
			gfx_dv   <= 1'b1;
			gfx_data <= row[127:96];
			row      <= {row[95:0], 32'd0};
			beats    <= beats - 3'd1;
		end
	end
end

endmodule
