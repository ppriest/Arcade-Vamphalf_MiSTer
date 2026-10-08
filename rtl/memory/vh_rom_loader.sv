// Fast ROM load: the .mra's address="0x30000000" has the HPS put the ROM image in DDR3 (an index-0
// download with no ioctl_wr); this copies it into SDRAM with the game in reset, one 8-byte granule per
// SDRAM write (the download port's granule mode, sdram.sv's burst write). The granule after the one
// being written is read from DDR3 meanwhile.
//
// Parts of the image the core also keeps in block RAM (the QS1000's u7, the EEPROM's default) are
// caught from the byte path's stream; for those the copy replays the granule's bytes, in address order,
// on tb_* as well: the top says which granules (tap_want for the granule at tap_addr).
//
// After Arcade-Seta_MiSTer's rom_loader.sv (546242b; from Fuuki, via Psikyo): the same trigger and
// ddram_phy client, a granule written whole instead of as four words, and the read-ahead.

module vh_rom_loader (
	input  logic         clk,
	input  logic         reset,

	input  logic [27:0]  length,     // bytes to copy, a multiple of 8

	input  logic         start,      // pulse: begin the copy
	output logic         busy,       // 1 while copying; hold the game in reset

	// ddram_phy: byte offset from 0x30000000; granule byte i in rdata[8*i +: 8]
	output logic         ddr_req,
	output logic [27:0]  ddr_addr,
	input  logic         ddr_busy,
	input  logic         ddr_valid,
	input  logic [63:0]  ddr_rdata,

	// SDRAM download port, granule mode: dl_addr 8-byte aligned, dl_gdata byte i at dl_addr + i
	output logic         dl_req,
	output logic [26:0]  dl_addr,
	output logic [63:0]  dl_gdata,
	input  logic         dl_busy,

	// byte replay of the granules the top asks for
	output logic [27:0]  tap_addr,   // the granule about to be written
	input  logic         tap_want,
	output logic         tb_wr,
	output logic [26:0]  tb_addr,
	output logic [7:0]   tb_dout
);

	// reader: fills gbuf whenever it is empty
	typedef enum logic [1:0] {R_IDLE, R_REQ, R_WAIT} rstate_t;
	rstate_t     rst_st;
	logic [27:0] rd_addr;
	logic        gfull;
	logic [27:0] gaddr;
	logic [63:0] gbuf;

	// writer: takes gbuf, writes it, replays its bytes if asked
	typedef enum logic [1:0] {W_IDLE, W_REQ, W_WAIT} wstate_t;
	wstate_t     wst;
	logic [27:0] waddr;
	logic [63:0] wbuf;
	logic [3:0]  tap_n;          // bytes still to replay
	wire  [2:0]  tap_i = 3'(4'd8 - tap_n);
	logic        active;

	assign busy     = active;
	assign ddr_req  = rst_st == R_REQ;
	assign ddr_addr = rd_addr;
	assign dl_req   = wst == W_REQ;
	assign dl_addr  = waddr[26:0];
	assign dl_gdata = wbuf;
	assign tap_addr = gaddr;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			active <= 1'b0;
			rst_st <= R_IDLE;
			wst    <= W_IDLE;
			gfull  <= 1'b0;
			tap_n  <= 4'd0;
			tb_wr  <= 1'b0;
		end else begin
			tb_wr <= 1'b0;

			if (start && !active) begin
				active  <= 1'b1;
				rd_addr <= 28'd0;
				gfull   <= 1'b0;
				rst_st  <= R_REQ;
				wst     <= W_IDLE;
				tap_n   <= 4'd0;
			end

			// reader
			case (rst_st)
				R_REQ:  if (ddr_busy) rst_st <= R_WAIT;          // the phy took the request
				R_WAIT: if (ddr_valid) begin
					gbuf    <= ddr_rdata;
					gaddr   <= rd_addr;
					gfull   <= 1'b1;
					rd_addr <= rd_addr + 28'd8;
					rst_st  <= R_IDLE;
				end
				default: if (active && !gfull && rd_addr < length) rst_st <= R_REQ;
			endcase

			// byte replay, one per clock, beside the SDRAM write
			if (tap_n != 4'd0) begin
				tb_wr   <= 1'b1;
				tb_addr <= {waddr[26:3], tap_i};
				tb_dout <= wbuf[{tap_i, 3'b000} +: 8];
				tap_n   <= tap_n - 4'd1;
			end

			// writer
			case (wst)
				W_IDLE: if (active && gfull) begin
					wbuf  <= gbuf;
					waddr <= gaddr;
					tap_n <= tap_want ? 4'd8 : 4'd0;
					gfull <= 1'b0;
					wst   <= W_REQ;
				end
				W_REQ:  if (dl_busy) wst <= W_WAIT;
				W_WAIT: if (!dl_busy && tap_n == 4'd0) begin
					wst <= W_IDLE;
					if (waddr + 28'd8 >= length) active <= 1'b0;
				end
				default: wst <= W_IDLE;
			endcase
		end
	end

endmodule
