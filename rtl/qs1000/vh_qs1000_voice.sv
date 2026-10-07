// QS1000 wavetable engine, as MAME models it (devices/sound/qs1000.cpp; scripts/qs1000_model.py is
// the same model in Python and the bench's reference).
//
// MAME runs the engine at 24 MHz / 32 = 750 kHz: per tick every playing voice outputs one sample
// (8-bit PCM, or OKI ADPCM decoded one nibble per address step), scaled by left/right and voice volume,
// and advances its address by an 18-bit-fraction pitch accumulator. No envelope, no filter, no looping:
// a voice stops at its loop end (all as MAME, which marks them TODO).
//
// Register writes (0x200-0x211 of the 8052's data space, `wr_*`) and ticks (`tick`) enter one queue in
// arrival order and are applied in that order, so the output sequence is MAME's even when a key-on
// waits for its ROM reads; the engine catches up between ticks (32 voices take 32 clocks plus the
// pipeline, of the 74.7 a tick has at 56 MHz).
//
// Sample ROM reads go through rom_*: a request for one 16-byte line of the sample region (line address
// = byte address >> 4), answered by rom_ack with the line, byte 0 in [127:120]. Each voice keeps two
// lines (the one it reads and the next, prefetched); the pipeline stalls only if the line it needs has
// not arrived.
//
// mix_valid pulses once per tick with the left and right sums (before MAME's /4096); out_l/out_r are
// the 16-bit output, the mean of 16 ticks (46.875 kHz), clamped.

module vh_qs1000_voice (
	input              clk,
	input              rst,

	input              wr,
	input       [4:0]  wr_off,          // register - 0x200
	input       [7:0]  wr_data,
	input              tick,            // 750 kHz
	input              bal_pcb,         // the PCB recording's balance: ADPCM x2, PCM x4 (the core); 0 MAME's x4, x1 (benches)

	output reg         rom_req,         // held until rom_ack
	output reg  [19:0] rom_line,
	input              rom_ack,
	input      [127:0] rom_data,

	output reg         mix_valid,
	output reg signed [31:0] mix_l,
	output reg signed [31:0] mix_r,
	output reg signed [15:0] out_l,
	output reg signed [15:0] out_r,

	output reg  [15:0] dbg_drops,       // queue overflows (a write or tick lost)
	output reg  [15:0] dbg_stalls       // pipeline stalls on a missing sample line
);

// ---------------------------------------------------------------- event queue
// {tick, off[4:0], data[7:0]}
localparam QW = 14;
reg  [QW-1:0] q_mem [0:255];
reg  [7:0]  q_wr, q_rd;
wire [7:0]  q_cnt = q_wr - q_rd;
reg  [QW-1:0] q_head;
// a write arriving with a tick is queued a clock later, after it: it belongs to the next sample, as a
// write MAME stamps with the current tick is applied before that tick's sample (the 8052 writes once in
// 28 clocks or more, so the held write is never overtaken)
reg         wr_h;
reg  [12:0] wr_hd;
wire        q_push = tick || wr || wr_h;
wire [QW-1:0] q_in = tick ? {1'b1, 13'd0} : wr_h ? {1'b0, wr_hd} : {1'b0, wr_off, wr_data};
always @(posedge clk) begin
	if (rst) begin
		q_wr <= 8'd0;
		wr_h <= 1'b0;
		dbg_drops <= 16'd0;
	end else begin
		if (q_push) begin
			if (q_cnt != 8'd255) begin
				q_mem[q_wr] <= q_in;
				q_wr <= q_wr + 8'd1;
			end else dbg_drops <= dbg_drops + 16'd1;
		end
		if (tick && wr) begin wr_h <= 1'b1; wr_hd <= {wr_off, wr_data}; end
		else if (!tick && wr_h) wr_h <= 1'b0;
	end
	q_head <= q_mem[q_rd];
end

// ---------------------------------------------------------------- registers
reg  [7:0]  wave [0:17];
// per-voice volumes, written by key-on and the direct channel writes (E_POP, a clock later), read with
// the voice in S1 so that S2 has them
reg  [7:0]  lv_mem [0:31], rv_mem [0:31], vv_mem [0:31];
reg  [7:0]  lv_q, rv_q, vv_q;
reg         lv_we, rv_we, vv_we;
reg  [4:0]  vo_wa;
reg  [7:0]  lv_wd, rv_wd, vv_wd;
reg  [4:0]  s1_ch;
always @(posedge clk) begin
	if (lv_we) lv_mem[vo_wa] <= lv_wd;
	if (rv_we) rv_mem[vo_wa] <= rv_wd;
	if (vv_we) vv_mem[vo_wa] <= vv_wd;
	lv_q <= lv_mem[s1_ch];
	rv_q <= rv_mem[s1_ch];
	vv_q <= vv_mem[s1_ch];
end

// ---------------------------------------------------------------- voice state
// {flags[1:0] (playing, adpcm), step[5:0], sig[11:0], aaddr[24:0], freq[15:0], acc[17:0],
//  lend[23:0], start[23:0], addr[23:0]}
localparam SW = 2 + 6 + 12 + 25 + 16 + 18 + 24 + 24 + 24;   // 151
reg  [SW-1:0] st_mem [0:31];
reg  [SW-1:0] st_q;
reg         st_we;
reg  [4:0]  st_wa;
reg  [SW-1:0] st_wd;
always @(posedge clk) begin
	if (st_we) st_mem[st_wa] <= st_wd;
	st_q <= st_mem[st_ra];
end

// sample lines: {voice, slot} -> 16 bytes; tags in registers
reg  [127:0] ln_mem [0:63];
reg  [127:0] ln_q;
reg  [5:0]  ln_ra;
reg         ln_we;
reg  [5:0]  ln_wa;
reg  [127:0] ln_wd;
always @(posedge clk) begin
	if (ln_we) ln_mem[ln_wa] <= ln_wd;
	ln_q <= ln_mem[ln_ra];
end
reg  [63:0] tag_v;
reg  [19:0] tg0_mem [0:31], tg1_mem [0:31];
reg  [19:0] tg0_q, tg1_q;
reg         tg_we;
reg  [5:0]  tg_wa;              // {voice, slot}
reg  [19:0] tg_wd;
reg  [4:0]  st_ra;
always @(posedge clk) begin
	if (tg_we && !tg_wa[0]) tg0_mem[tg_wa[5:1]] <= tg_wd;
	if (tg_we &&  tg_wa[0]) tg1_mem[tg_wa[5:1]] <= tg_wd;
	tg0_q <= tg0_mem[st_ra];
	tg1_q <= tg1_mem[st_ra];
end

// ---------------------------------------------------------------- ADPCM (okiadpcm.cpp)
function [11:0] stepval(input [5:0] s);
	case (s)
		6'd0: stepval = 16;    6'd1: stepval = 17;    6'd2: stepval = 19;    6'd3: stepval = 21;
		6'd4: stepval = 23;    6'd5: stepval = 25;    6'd6: stepval = 28;    6'd7: stepval = 31;
		6'd8: stepval = 34;    6'd9: stepval = 37;    6'd10: stepval = 41;   6'd11: stepval = 45;
		6'd12: stepval = 50;   6'd13: stepval = 55;   6'd14: stepval = 60;   6'd15: stepval = 66;
		6'd16: stepval = 73;   6'd17: stepval = 80;   6'd18: stepval = 88;   6'd19: stepval = 97;
		6'd20: stepval = 107;  6'd21: stepval = 118;  6'd22: stepval = 130;  6'd23: stepval = 143;
		6'd24: stepval = 157;  6'd25: stepval = 173;  6'd26: stepval = 190;  6'd27: stepval = 209;
		6'd28: stepval = 230;  6'd29: stepval = 253;  6'd30: stepval = 279;  6'd31: stepval = 307;
		6'd32: stepval = 337;  6'd33: stepval = 371;  6'd34: stepval = 408;  6'd35: stepval = 449;
		6'd36: stepval = 494;  6'd37: stepval = 544;  6'd38: stepval = 598;  6'd39: stepval = 658;
		6'd40: stepval = 724;  6'd41: stepval = 796;  6'd42: stepval = 876;  6'd43: stepval = 963;
		6'd44: stepval = 1060; 6'd45: stepval = 1166; 6'd46: stepval = 1282; 6'd47: stepval = 1411;
		default: stepval = 1552;
	endcase
endfunction

// ---------------------------------------------------------------- engine
localparam [3:0] E_IDLE = 0, E_POP = 1, E_TICK = 2, E_DRAIN = 3, E_KON = 4, E_KWAIT = 5, E_KDONE = 6,
                 E_OUT = 7, E_CLR = 8;
reg  [4:0]  clr_n;
reg  [3:0]  es;
reg  [4:0]  kch;                // the voice being keyed on
reg  [2:0]  kstep;              // key-on reads: 0,1 table lines; 2,3 descriptor lines
reg  [255:0] kbuf;              // two consecutive lines
reg  [23:0] kbase;              // address of the bytes in kbuf[255:248]
reg  [15:0] kfreq;

// fetch unit: one request at a time, from the key-on sequence or the pipeline
reg         f_busy;
reg         f_kon;              // the line is for the key-on sequence
reg  [5:0]  f_slot;             // {voice, slot} for a sample line
reg  [127:0] f_data;
reg         f_done;
// line requests, one per {voice, slot} at most
reg  [63:0] pf_want;
reg  [19:0] pf_mem [0:63];
reg  [19:0] pf_q;
reg         pf_we;
reg  [5:0]  pf_wa;
reg  [19:0] pf_wd;
reg  [5:0]  pf_pick;            // the lowest requesting slot
reg         f_pick;             // a slot was picked last clock: its line is in pf_q
always @(posedge clk) begin
	if (pf_we) pf_mem[pf_wa] <= pf_wd;
	pf_q <= pf_mem[pf_pick];
end
integer j;
always @* begin
	pf_pick = 6'd0;
	for (j = 63; j >= 0; j = j - 1)
		if (pf_want[j]) pf_pick = j[5:0];
end

// pipeline
reg  [4:0]  s0_ch;
reg         s0_v, s1_v, s2_v;
reg  [4:0]  s2_ch;
reg         stall;
// S1 decode
wire        p_play = st_q[150];
wire        p_adp  = st_q[149];
wire [5:0]  p_step = st_q[148:143];
wire signed [11:0] p_sig = st_q[142:131];
wire [24:0] p_aadr = st_q[130:106];
wire [15:0] p_freq = st_q[105:90];
wire [17:0] p_acc  = st_q[89:72];
wire [23:0] p_lend = st_q[71:48];
wire [23:0] p_start = st_q[47:24];
wire [23:0] p_addr = st_q[23:0];
wire        p_stop = p_play && (p_addr >= p_lend);
wire [25:0] p_pos  = {2'b0, p_start} + {p_aadr[24], p_aadr};
wire        p_dec  = p_adp && (p_pos != {2'b0, p_addr});
wire [24:0] p_na   = p_aadr + 25'd1;
wire [23:0] p_byte = p_adp ? (p_start + p_na[24:1]) : p_addr;
wire        p_need = p_play && !p_stop && (!p_adp || p_dec);
wire        p_slot = p_byte[4];
wire [5:0]  p_ix   = {s1_ch, p_slot};
wire [5:0]  p_ixn  = {s1_ch, !p_slot};
wire [19:0] p_tag  = p_slot ? tg1_q : tg0_q;
wire [19:0] p_tagn = p_slot ? tg0_q : tg1_q;
wire        p_hit  = tag_v[p_ix] && p_tag == p_byte[23:4];
wire        p_nhit = tag_v[p_ixn] && p_tagn == p_byte[23:4] + 20'd1;
wire        p_miss = s1_v && p_need && !p_hit;

// S2 registers
reg  [SW-1:0] s2_st;
reg         s2_need, s2_stop, s2_dec;
reg  [3:0]  s2_bix;
reg         s2_nib;
reg  [24:0] s2_na;
reg  signed [31:0] acc_l, acc_r;
reg  signed [35:0] dec_l, dec_r;
reg  [3:0]  dec_n;

wire [7:0]  s2_byte = ln_q[127 - 8*s2_bix -: 8];
wire [3:0]  s2_nibv = s2_nib ? s2_byte[3:0] : s2_byte[7:4];
wire [11:0] sv = stepval(s2_st[148:143]);
wire signed [13:0] s2_diff_mag = {2'b0, sv[11:0] & {12{s2_nibv[2]}}} + {3'b0, sv[11:1] & {11{s2_nibv[1]}}}
                               + {4'b0, sv[11:2] & {10{s2_nibv[0]}}} + {5'b0, sv[11:3]};
wire signed [13:0] s2_sig_raw = {{2{s2_st[142]}}, s2_st[142:131]} + (s2_nibv[3] ? -s2_diff_mag : s2_diff_mag);
wire signed [11:0] s2_sig_new = (s2_sig_raw > 14'sd2047) ? 12'sd2047 : (s2_sig_raw < -14'sd2048) ? -12'sd2048 : s2_sig_raw[11:0];
wire signed [6:0] s2_shift = s2_nibv[2] ? (s2_nibv[1:0] == 2'd0 ? 7'sd2 : s2_nibv[1:0] == 2'd1 ? 7'sd4 :
                                           s2_nibv[1:0] == 2'd2 ? 7'sd6 : 7'sd8) : -7'sd1;
wire signed [7:0] s2_step_raw = $signed({2'b0, s2_st[148:143]}) + s2_shift;
wire [5:0]  s2_step_new = (s2_step_raw > 8'sd48) ? 6'd48 : (s2_step_raw < 0) ? 6'd0 : s2_step_raw[5:0];
wire        s2_adp = s2_st[149];
wire signed [11:0] s2_sig_out = (s2_adp && s2_dec) ? s2_sig_new : $signed(s2_st[142:131]);
wire signed [8:0] s2_res = s2_adp ? {{1{s2_sig_out[11]}}, s2_sig_out[11:4]} : ($signed({1'b0, s2_byte}) - 9'sd128);
// S3: sample x voice volume, S4: x left and right volume, S5: accumulate
reg         r3_v, r4_v, r5_v;
reg         r3_adp, r4_adp, r5_adp;
reg  signed [8:0]  r3_res;
reg  [7:0]  r3_vv, r3_lv, r3_rv, r4_lv, r4_rv;
reg  signed [17:0] r4_s;
reg  signed [27:0] r5_pl, r5_pr;
wire [18:0] s2_accsum = {1'b0, s2_st[89:72]} + {3'b0, s2_st[105:90]};
wire [23:0] s2_addr_new = s2_st[23:0] + {23'd0, s2_accsum[18]};

integer i;
always @(posedge clk) begin
	st_we <= 1'b0;
	ln_we <= 1'b0;
	tg_we <= 1'b0;
	pf_we <= 1'b0;
	lv_we <= 1'b0; rv_we <= 1'b0; vv_we <= 1'b0;
	mix_valid <= 1'b0;
	f_done <= 1'b0;

	// fetch unit: completions
	if (rom_req && rom_ack) begin
		rom_req <= 1'b0;
		f_busy <= 1'b0;
		if (f_kon) begin
			f_data <= rom_data;
			f_done <= 1'b1;
		end else begin
			ln_we <= 1'b1;
			ln_wa <= f_slot;
			ln_wd <= rom_data;
		end
	end
	// a filled line becomes valid the clock after its data is written
	if (ln_we) begin
		tag_v[ln_wa] <= 1'b1;
	end

	if (rst) begin
		es <= E_CLR;
		clr_n <= 5'd0;
		q_rd <= 8'd0;
		rom_req <= 1'b0;
		f_busy <= 1'b0;
		f_pick <= 1'b0;
		tag_v <= 64'd0;
		pf_want <= 64'd0;
		s0_v <= 1'b0; s1_v <= 1'b0; s2_v <= 1'b0;
		r3_v <= 1'b0; r4_v <= 1'b0; r5_v <= 1'b0;
		dbg_stalls <= 16'd0;
		acc_l <= 0; acc_r <= 0; dec_l <= 0; dec_r <= 0; dec_n <= 4'd0;
		out_l <= 16'sd0; out_r <= 16'sd0;
		for (i = 0; i < 18; i = i + 1) wave[i] <= 8'd0;
		kch <= 5'd0;
	end else begin
		r3_v <= 1'b0;
		// line requests (demand and prefetch) go out, lowest {voice, slot} first, whenever the fetch unit
		// is free and no key-on is reading; the slot's tag changes now and turns valid with the data
		// (not a slot whose line is being written to pf_mem this clock: pf_q would read the old one)
		if (!f_busy && !rom_req && es != E_KON && es != E_KWAIT && pf_want != 64'd0 &&
		    !(pf_we && pf_wa == pf_pick)) begin
			f_busy <= 1'b1;
			f_kon <= 1'b0;
			f_pick <= 1'b1;
			f_slot <= pf_pick;
			pf_want[pf_pick] <= 1'b0;
			tag_v[pf_pick] <= 1'b0;
		end
		if (f_pick) begin
			f_pick <= 1'b0;
			rom_req <= 1'b1;
			rom_line <= pf_q;
			tg_we <= 1'b1;
			tg_wa <= f_slot;
			tg_wd <= pf_q;
		end

		case (es)
			E_IDLE: begin
				if (q_cnt != 8'd0) begin
					es <= E_POP;          // q_head is read from q_rd this clock
				end
			end
			E_POP: begin
				q_rd <= q_rd + 8'd1;
				if (q_head[13]) begin
					es <= E_TICK;
					s0_ch <= 5'd0; s0_v <= 1'b1;
					acc_l <= 0; acc_r <= 0;
				end else begin
					es <= E_IDLE;
					case (q_head[12:8])
						5'h00: begin
							if (q_head[7:0] == 8'd0) begin
								kch <= wave[14][4:0];
								vo_wa <= wave[14][4:0];
								lv_we <= 1'b1; lv_wd <= wave[6];
								rv_we <= 1'b1; rv_wd <= wave[7];
								vv_we <= 1'b1; vv_wd <= wave[8];
								kbase <= {wave[1], wave[2], wave[3]};
								kstep <= 3'd0;
								es <= E_KON;
							end
						end
						5'h01, 5'h02, 5'h03, 5'h04, 5'h05, 5'h06, 5'h07, 5'h08, 5'h09, 5'h0a, 5'h0b, 5'h0c, 5'h0d: begin
							if (wave[17] == 8'd3) begin
								vo_wa <= wave[14][4:0];
								if (q_head[12:8] == 5'h06) begin lv_we <= 1'b1; lv_wd <= q_head[7:0]; end
								if (q_head[12:8] == 5'h07) begin rv_we <= 1'b1; rv_wd <= q_head[7:0]; end
								if (q_head[12:8] == 5'h08) begin vv_we <= 1'b1; vv_wd <= q_head[7:0]; end
							end else wave[q_head[12:8]] <= q_head[7:0];
						end
						default: if (q_head[12:8] <= 5'h11) wave[q_head[12:8]] <= q_head[7:0];
					endcase
				end
			end

			// ---- key-on: read the table entry (6 bytes at kbase) and the descriptor (9 bytes)
			E_KON: if (!f_busy && !rom_req) begin
				// kstep 0/2: the line holding kbase; 1/3: the next line
				f_busy <= 1'b1;
				f_kon <= 1'b1;
				rom_req <= 1'b1;
				rom_line <= kbase[23:4] + {19'd0, kstep[0]};
				es <= E_KWAIT;
			end
			E_KWAIT: if (f_done) begin
				if (!kstep[0]) kbuf[255:128] <= f_data;
				else kbuf[127:0] <= f_data;
				if (kstep == 3'd0 || kstep == 3'd2) begin
					kstep <= kstep + 3'd1;
					es <= E_KON;
				end else es <= E_KDONE;
			end
			E_KDONE: begin
				if (kstep == 3'd1) begin
					// table entry: freq at +0, descriptor base at +4 (16-bit, so in the first 64 KB)
					kfreq <= kbuf[255 - 8*kbase[3:0] -: 16];
					if (kbuf[255 - 8*kbase[3:0] -: 16] == 16'd0) es <= E_IDLE;     // MAME: return
					else begin
						kbase <= {8'd0, kbuf[255 - 8*({1'b0, kbase[3:0]} + 5'd4) -: 16]};
						kstep <= 3'd2;
						es <= E_KON;
					end
				end else begin
					// descriptor: start (3 bytes), loop start (unused while looping is off), loop end; byte 8 bit 3 ADPCM
					st_we <= 1'b1;
					st_wa <= kch;
					st_wd <= {1'b1, kbuf[255 - 8*({1'b0, kbase[3:0]} + 5'd8) - 4],      // playing, adpcm (byte 8 bit 3)
					          6'd0, 12'd0, 25'h1ffffff,                          // step, signal, adpcm address -1
					          kfreq, 18'd0,
					          kbuf[255 - 8*kbase[3:0] -: 4], kbuf[255 - 8*({1'b0, kbase[3:0]} + 5'd5) - 4 -: 4],
					          kbuf[255 - 8*({1'b0, kbase[3:0]} + 5'd6) -: 16],             // loop end
					          kbuf[255 - 8*kbase[3:0] -: 24],                      // start
					          kbuf[255 - 8*kbase[3:0] -: 24]};                     // addr = start
					tag_v[{kch, 1'b0}] <= 1'b0;
					tag_v[{kch, 1'b1}] <= 1'b0;
					pf_want[{kch, 1'b0}] <= 1'b0;
					pf_want[{kch, 1'b1}] <= 1'b0;
					es <= E_IDLE;
				end
			end

			// ---- one tick: voices 0..31 through S0 (state read), S1 (line check), S2 (sample, write back),
			// then S3-S5 (volumes, accumulate) below
			E_TICK, E_DRAIN: begin
				if (!stall) begin
					// S0 -> S1
					s1_v <= s0_v;
					s1_ch <= s0_ch;
					if (s0_v) begin
						if (s0_ch == 5'd31) s0_v <= 1'b0;
						s0_ch <= s0_ch + 5'd1;
					end
					// S1 -> S2
					s2_v <= s1_v;
					s2_ch <= s1_ch;
					s2_st <= st_q;
					s2_need <= p_need;
					s2_stop <= p_stop;
					s2_dec <= p_dec;
					s2_bix <= p_byte[3:0];
					s2_nib <= p_na[0];
					s2_na <= p_na;
					// prefetch the next line of a voice reading from this one
					if (s1_v && p_need && p_hit && !p_nhit && !pf_want[p_ixn] && !(f_busy && f_slot == p_ixn)) begin
						pf_want[p_ixn] <= 1'b1;
						pf_we <= 1'b1; pf_wa <= p_ixn; pf_wd <= p_byte[23:4] + 20'd1;
					end
				end else begin
					s2_v <= 1'b0;
					dbg_stalls <= dbg_stalls + 16'd1;
					if (!pf_want[p_ix] && !(f_busy && f_slot == p_ix)) begin
						pf_want[p_ix] <= 1'b1;
						pf_we <= 1'b1; pf_wa <= p_ix; pf_wd <= p_byte[23:4];
					end
				end

				// S2: commit voice s2_ch
				if (s2_v) begin
					if (s2_st[150]) begin
						st_we <= 1'b1;
						st_wa <= s2_ch;
						if (s2_stop) st_wd <= {1'b0, s2_st[149:0]};
						else begin
							st_wd <= {s2_st[150:149],
							          (s2_adp && s2_dec) ? s2_step_new : s2_st[148:143],
							          s2_sig_out,
							          (s2_adp && s2_dec) ? s2_na : s2_st[130:106],
							          s2_st[105:90], s2_accsum[17:0], s2_st[71:24], s2_addr_new};
							r3_v <= 1'b1;
							r3_adp <= s2_adp;
							r3_res <= s2_res;
							r3_vv <= vv_q;
							r3_lv <= lv_q;
							r3_rv <= rv_q;
						end
					end
					if (s2_ch == 5'd31) es <= E_OUT;
				end
			end
			E_CLR: begin                     // after reset every voice is stopped, as MAME's device_reset
				st_we <= 1'b1;
				st_wa <= clr_n;
				st_wd <= {SW{1'b0}};
				clr_n <= clr_n + 5'd1;
				if (clr_n == 5'd31) es <= E_IDLE;
			end
			E_OUT: if (!r3_v && !r4_v && !r5_v) begin      // the last voice has been accumulated
				mix_valid <= 1'b1;
				mix_l <= acc_l;
				mix_r <= acc_r;
				dec_l <= dec_l + acc_l;
				dec_r <= dec_r + acc_r;
				dec_n <= dec_n + 4'd1;
				if (dec_n == 4'd15) begin
					out_l <= clamp16((dec_l + acc_l) >>> 16);
					out_r <= clamp16((dec_r + acc_r) >>> 16);
					dec_l <= 0; dec_r <= 0;
				end
				es <= E_IDLE;
			end
			default: es <= E_IDLE;
		endcase

		r4_v <= r3_v;
		r4_adp <= r3_adp;
		r4_s <= r3_res * $signed({1'b0, r3_vv});
		r4_lv <= r3_lv;
		r4_rv <= r3_rv;
		r5_v <= r4_v;
		r5_adp <= r4_adp;
		r5_pl <= r4_s * $signed({1'b0, r4_lv});
		r5_pr <= r4_s * $signed({1'b0, r4_rv});
		if (r5_v) begin
			// MAME: ADPCM x4, PCM x1 (qs1000.cpp:484, :513). The PCB balance (MAME_KLUDGES.md, Sound): ADPCM x2,
			// PCM x4, PCM 18 dB higher against ADPCM than MAME has it
			acc_l <= acc_l + (r5_adp ? (bal_pcb ? {{3{r5_pl[27]}}, r5_pl, 1'b0} : {{2{r5_pl[27]}}, r5_pl, 2'b0})
			                         : (bal_pcb ? {{2{r5_pl[27]}}, r5_pl, 2'b0} : {{4{r5_pl[27]}}, r5_pl}));
			acc_r <= acc_r + (r5_adp ? (bal_pcb ? {{3{r5_pr[27]}}, r5_pr, 1'b0} : {{2{r5_pr[27]}}, r5_pr, 2'b0})
			                         : (bal_pcb ? {{2{r5_pr[27]}}, r5_pr, 2'b0} : {{4{r5_pr[27]}}, r5_pr}));
		end
	end
end

always @* begin
	stall = s1_v && p_miss;
	st_ra = stall ? s1_ch : s0_ch;      // a stalled voice reads its state again
	ln_ra = p_ix;
end

function signed [15:0] clamp16(input signed [35:0] v);
	clamp16 = (v > 36'sd32767) ? 16'sd32767 : (v < -36'sd32768) ? -16'sd32768 : v[15:0];
endfunction

endmodule
