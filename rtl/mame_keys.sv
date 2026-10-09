// MAME's default keys (src/emu/inpttype.ipp) in hps_io's joystick layout, to
// OR into joystick_0/1: right, left, down, up at bits 0-3, buttons 1-6 at 4-9,
// Start, Coin, Pause, Service at the J1 line's own positions (parameters).
// BUTTONS limits the button keys decoded, so a J1 line with fewer than six
// buttons keeps its Start and Coin bits free of them.
//
//   P1  arrows, LCtrl LAlt Space LShift Z X, 1 start, 5 coin
//   P2  R F D G, A S Q W E (MAME gives P2 no sixth key), 2 start, 6 coin
//   F2 service (test) switch, 9 and 0 service coins 1 and 2, P pause
//   alt (solitaire's PORT_CODEs, which replace P1's button keys): Z X C V to buttons 1-4,
//   B N M A S D F to bits 13-19 (its buttons 5-11)
//
// Key state is per key, so a pad and the keyboard can both be held. hps_io
// only passes keys while the OSD is closed.
module mame_keys #(
	parameter BUTTONS = 6,
	parameter START   = 10,
	parameter COIN    = 11,
	parameter PAUSE   = 12,
	parameter SERVICE = 13
) (
	input             clk,              // hps_io's clk_sys
	input      [10:0] ps2_key,          // [10] toggles per event, [9] pressed, [8] E0 prefix, [7:0] set-2 code
	input             alt,
	output reg [31:0] key0 = 32'd0,
	output reg [31:0] key1 = 32'd0,
	output reg  [1:0] svc_coin = 2'd0   // MAME's Service 1, 2: wire to the board's SERVICE1/2 bits, if any
);

wire p = ps2_key[9];
reg  tog = 1'b0;

always @(posedge clk) begin
	tog <= ps2_key[10];
	if (ps2_key[10] != tog)
		case (ps2_key[8:0])
			9'h175: key0[3]       <= p; // up
			9'h172: key0[2]       <= p; // down
			9'h16B: key0[1]       <= p; // left
			9'h174: key0[0]       <= p; // right
			9'h014: if (!alt) key0[4] <= p; // left ctrl
			9'h011: if (!alt) key0[5] <= p; // left alt
			9'h029: if (!alt) key0[6] <= p; // space
			9'h012: if (!alt) key0[7] <= p; // left shift
			9'h01A: if (alt) key0[4] <= p; else if (BUTTONS >= 5) key0[8] <= p; // Z
			9'h022: if (alt) key0[5] <= p; else if (BUTTONS >= 6) key0[9] <= p; // X
			9'h021: if (alt) key0[6]  <= p; // C
			9'h02A: if (alt) key0[7]  <= p; // V
			9'h032: if (alt) key0[13] <= p; // B
			9'h031: if (alt) key0[14] <= p; // N
			9'h03A: if (alt) key0[15] <= p; // M
			9'h016: key0[START]   <= p; // 1
			9'h02E: key0[COIN]    <= p; // 5
			9'h04D: key0[PAUSE]   <= p; // P
			9'h006: key0[SERVICE] <= p; // F2

			9'h02D: key1[3]       <= p; // R
			9'h02B: if (alt) key0[19] <= p; else key1[2] <= p; // F
			9'h023: if (alt) key0[18] <= p; else key1[1] <= p; // D
			9'h034: key1[0]       <= p; // G
			9'h01C: if (alt) key0[16] <= p; else key1[4] <= p; // A
			9'h01B: if (alt) key0[17] <= p; else key1[5] <= p; // S
			9'h015: key1[6]       <= p; // Q
			9'h01D: key1[7]       <= p; // W
			9'h024: if (BUTTONS >= 5) key1[8] <= p; // E
			9'h01E: key1[START]   <= p; // 2
			9'h036: key1[COIN]    <= p; // 6

			9'h046: svc_coin[0]   <= p; // 9
			9'h045: svc_coin[1]   <= p; // 0
			default: ;
		endcase
end

endmodule
