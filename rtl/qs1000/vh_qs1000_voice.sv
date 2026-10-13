// QS1000 wavetable engine, as MAME models it (devices/sound/qs1000.cpp; scripts/qs1000_model.py is
// the same model in Python and the bench's reference).
//
// MAME runs the engine at 24 MHz / 32 = 750 kHz: per tick every playing voice outputs one sample
// (8-bit PCM, or IMA ADPCM decoded one nibble per address step, high nibble first, its 16-bit signal
// wrapping instead of saturating: Arcade-Eolith_MiSTer docs/QS1000_FEATURES.md; MAME decodes OKI), scaled by left/right and voice volume,
// and advances its address by an 18-bit-fraction pitch accumulator. No envelope, no filter. With loop_pcb
// low, as MAME: no looping, a voice stops at its loop end, and key-off does nothing. With loop_pcb high
// (Arcade-Eolith_MiSTer docs/QS1000_FEATURES.md, Recording): a voice reaching its loop end goes back to its
// loop start (ADPCM with the decoder state it had there, MAME's disabled save/restore), key-off fades
// it out (`env`) instead, and [204] bends its pitch (`bendmul`; MAME ignores it).
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
	input              bal_pcb,         // 1: the PCB recording's balance (the core); 0: MAME's (benches). See S5
	input              loop_pcb,        // 1: looping, the key-off fade, pitch bend (the core); 0: MAME's (benches)

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
// a write arriving with a tick is queued a clock after it: it belongs to the next sample, as MAME
// applies a write stamped with the current tick before that tick's sample (the 8052 writes once in
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
// per-voice pitch: the table entry's rate (kf_mem, from key-on) and the bent rate the pipeline adds
// (fe_mem, rate x bendmul([204]) >> 14), rewritten at key-on and on each channel write of [204]
reg  [15:0] kf_mem [0:31];
reg  [17:0] fe_mem [0:31];
reg  [15:0] kf_q;
reg  [17:0] fe_q;
reg         kf_we, fe_we;
reg  [4:0]  kf_wa, fe_wa, b_ch;
reg  [15:0] kf_wd;
reg  [17:0] fe_wd;
always @(posedge clk) begin
	if (lv_we) lv_mem[vo_wa] <= lv_wd;
	if (rv_we) rv_mem[vo_wa] <= rv_wd;
	if (vv_we) vv_mem[vo_wa] <= vv_wd;
	if (kf_we) kf_mem[kf_wa] <= kf_wd;
	if (fe_we) fe_mem[fe_wa] <= fe_wd;
	lv_q <= lv_mem[s1_ch];
	rv_q <= rv_mem[s1_ch];
	vv_q <= vv_mem[s1_ch];
	fe_q <= fe_mem[s1_ch];
	kf_q <= kf_mem[b_ch];
end

// ---------------------------------------------------------------- voice state
// {sstep[6], ssig[15:12], step[6], sig[15:12],
//  env[15:0], ssig[11:0], sstep[5:0], lstart[23:0],
//  flags[1:0] (playing, adpcm), step[5:0], sig[11:0], aaddr[24:0], freq[15:0], acc[17:0],
//  lend[23:0], start[23:0], addr[23:0]}
// step/sig: the IMA decoder's step index (0-88) and signal, their top bits in the first field;
// ssig/sstep: its state before the nibble at lstart; env: the key-off fade
localparam SW = 10 + 16 + 12 + 6 + 24 + 2 + 6 + 12 + 25 + 16 + 18 + 24 + 24 + 24;   // 219
reg  [SW-1:0] st_mem [0:31];
reg  [SW-1:0] st_q;
reg         st_we;
reg  [4:0]  st_wa;
reg  [SW-1:0] st_wd;
always @(posedge clk) begin
	if (st_we) st_mem[st_wa] <= st_wd;
	st_q <= st_mem[st_ra];
end

// sample lines: {voice, slot} -> 16 bytes; each slot's line address in tg0_mem/tg1_mem, its valid bit in tag_v
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

// ---------------------------------------------------------------- ADPCM: IMA's step table
function [14:0] stepval(input [6:0] s);
	case (s)
		7'd0: stepval = 7;     7'd1: stepval = 8;     7'd2: stepval = 9;     7'd3: stepval = 10;
		7'd4: stepval = 11;    7'd5: stepval = 12;    7'd6: stepval = 13;    7'd7: stepval = 14;
		7'd8: stepval = 16;    7'd9: stepval = 17;    7'd10: stepval = 19;   7'd11: stepval = 21;
		7'd12: stepval = 23;   7'd13: stepval = 25;   7'd14: stepval = 28;   7'd15: stepval = 31;
		7'd16: stepval = 34;   7'd17: stepval = 37;   7'd18: stepval = 41;   7'd19: stepval = 45;
		7'd20: stepval = 50;   7'd21: stepval = 55;   7'd22: stepval = 60;   7'd23: stepval = 66;
		7'd24: stepval = 73;   7'd25: stepval = 80;   7'd26: stepval = 88;   7'd27: stepval = 97;
		7'd28: stepval = 107;  7'd29: stepval = 118;  7'd30: stepval = 130;  7'd31: stepval = 143;
		7'd32: stepval = 157;  7'd33: stepval = 173;  7'd34: stepval = 190;  7'd35: stepval = 209;
		7'd36: stepval = 230;  7'd37: stepval = 253;  7'd38: stepval = 279;  7'd39: stepval = 307;
		7'd40: stepval = 337;  7'd41: stepval = 371;  7'd42: stepval = 408;  7'd43: stepval = 449;
		7'd44: stepval = 494;  7'd45: stepval = 544;  7'd46: stepval = 598;  7'd47: stepval = 658;
		7'd48: stepval = 724;  7'd49: stepval = 796;  7'd50: stepval = 876;  7'd51: stepval = 963;
		7'd52: stepval = 1060; 7'd53: stepval = 1166; 7'd54: stepval = 1282; 7'd55: stepval = 1411;
		7'd56: stepval = 1552; 7'd57: stepval = 1707; 7'd58: stepval = 1878; 7'd59: stepval = 2066;
		7'd60: stepval = 2272; 7'd61: stepval = 2499; 7'd62: stepval = 2749; 7'd63: stepval = 3024;
		7'd64: stepval = 3327; 7'd65: stepval = 3660; 7'd66: stepval = 4026; 7'd67: stepval = 4428;
		7'd68: stepval = 4871; 7'd69: stepval = 5358; 7'd70: stepval = 5894; 7'd71: stepval = 6484;
		7'd72: stepval = 7132; 7'd73: stepval = 7845; 7'd74: stepval = 8630; 7'd75: stepval = 9493;
		7'd76: stepval = 10442; 7'd77: stepval = 11487; 7'd78: stepval = 12635; 7'd79: stepval = 13899;
		7'd80: stepval = 15289; 7'd81: stepval = 16818; 7'd82: stepval = 18500; 7'd83: stepval = 20350;
		7'd84: stepval = 22385; 7'd85: stepval = 24623; 7'd86: stepval = 27086; 7'd87: stepval = 29794;
		default: stepval = 32767;
	endcase
endfunction

// ---------------------------------------------------------------- pitch bend: [204], bit 7 up, bits 6-0 the
// magnitude v; the rate x (1 + v/128) up, x (1 - v/256) down, in 2.14 (Arcade-Eolith_MiSTer
// docs/QS1000_FEATURES.md: +16 at +195 cents on Hidden Catch's PCB, -24..-2 at 6.8 cents a step on MIDI recordings)
function [15:0] bendmul(input [7:0] v);
	bendmul = v[7] ? 16'd16384 + {2'd0, v[6:0], 7'd0} : 16'd16384 - {3'd0, v[6:0], 6'd0};
endfunction

// ---------------------------------------------------------------- engine
localparam [3:0] E_IDLE = 0, E_POP = 1, E_TICK = 2, E_DRAIN = 3, E_KON = 4, E_KWAIT = 5, E_KDONE = 6,
                 E_OUT = 7, E_CLR = 8, E_B1 = 9, E_B2 = 10, E_B3 = 11;
reg  [4:0]  clr_n;
reg  [3:0]  es;
reg  [4:0]  kch;                // the voice being keyed on
reg  [2:0]  kstep;              // key-on reads: 0,1 the table entry's line and the next; 2,3 the descriptor's
reg  [255:0] kbuf;              // the line holding kbase, then the next
reg  [23:0] kbase;              // table entry, then descriptor address
reg  [15:0] kfreq;
// the bent rate: at key-on from kfreq and the staged [204] (stable while the key-on reads, as the queue
// waits), registered over the reads; on a channel write of [204], from kf_mem over E_B1-E_B3
reg  [15:0] kmul, bmul;
reg  [31:0] kprod, bprod;
reg  [7:0]  b_val;
// key-off fade: rel_v marks the voices keyed off since their key-on (loop_pcb). env -= env >> 8 on every
// 732nd tick, a time constant of 256 x 732 ticks, 0.25 s at 750 kHz (HACKS.md: one rate for every sample)
reg  [31:0] rel_v;
reg  [9:0]  env_ctr;
reg         env_go;             // this tick decays the fading voices

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
wire [24:0] p_aadr = st_q[130:106];
wire [15:0] p_freq = st_q[105:90];
wire [17:0] p_acc  = st_q[89:72];
wire [23:0] p_lend = st_q[71:48];
wire [23:0] p_start = st_q[47:24];
wire [23:0] p_addr = st_q[23:0];
// a looping voice never gets here at its loop end: S2 writes it back wrapped (s2_wrap)
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
wire [6:0]  s2_step = {s2_st[213], s2_st[148:143]};
wire [15:0] s2_sig  = {s2_st[212:209], s2_st[142:131]};
wire [14:0] sv = stepval(s2_step);
wire [15:0] s2_diff_mag = {1'b0, sv & {15{s2_nibv[2]}}} + {2'b0, sv[14:1] & {14{s2_nibv[1]}}}
                        + {3'b0, sv[14:2] & {13{s2_nibv[0]}}} + {4'b0, sv[14:3]};
wire [15:0] s2_sig_new = s2_nibv[3] ? s2_sig - s2_diff_mag : s2_sig + s2_diff_mag;      // wraps
wire signed [6:0] s2_shift = s2_nibv[2] ? (s2_nibv[1:0] == 2'd0 ? 7'sd2 : s2_nibv[1:0] == 2'd1 ? 7'sd4 :
                                           s2_nibv[1:0] == 2'd2 ? 7'sd6 : 7'sd8) : -7'sd1;
wire signed [8:0] s2_step_raw = $signed({2'b0, s2_step}) + s2_shift;
wire [6:0]  s2_step_new = (s2_step_raw > 9'sd88) ? 7'd88 : (s2_step_raw < 0) ? 7'd0 : s2_step_raw[6:0];
wire        s2_adp = s2_st[149];
wire [15:0] s2_sig_out = (s2_adp && s2_dec) ? s2_sig_new : s2_sig;
wire signed [8:0] s2_res = s2_adp ? {s2_sig_out[15], s2_sig_out[15:8]} : ($signed({1'b0, s2_byte}) - 9'sd128);
// S3: sample x voice volume, S4: x left and right volume, S5: accumulate
reg         r3_v, r4_v, r5_v;
reg         r3_adp, r4_adp, r5_adp;
reg  signed [8:0]  r3_res;
reg  [7:0]  r3_vv, r3_lv, r3_rv, r4_lv, r4_rv;
reg  signed [17:0] r4_s;
reg  signed [27:0] r5_pl, r5_pr;
// the rate is fe_q, the bent one (fe_mem, read with the voice in S1); with loop_pcb low it is the entry's rate
wire [18:0] s2_accsum = {1'b0, s2_st[89:72]} + {1'b0, fe_q};
wire [23:0] s2_addr_new = s2_st[23:0] + {23'd0, s2_accsum[18]};
// loop_pcb: the nibble decoded is lstart's, so its pre-decode state is the one to restore at each wrap;
// and the address after this tick reaches lend, so the voice is written back at lstart, its nibble index
// one before, with that state: the next tick decodes and outputs lstart's sample, as MAME's disabled code
// does on finding addr >= loop_end
wire [23:0] s2_lst = s2_st[174:151];
wire        s2_save = loop_pcb && s2_adp && s2_dec && (s2_st[47:24] + s2_na[23:0] == s2_lst);
wire        s2_wrap = loop_pcb && (s2_lst < s2_st[71:48]) &&
                      (s2_st[23:0] >= s2_st[71:48] || (s2_accsum[18] && s2_st[23:0] + 24'd1 == s2_st[71:48]));
wire [6:0]  s2_rstep = s2_save ? s2_step : {s2_st[218], s2_st[180:175]};
wire [15:0] s2_rsig  = s2_save ? s2_sig : {s2_st[217:214], s2_st[192:181]};
wire [6:0]  s2_nstep = s2_wrap ? s2_rstep : (s2_adp && s2_dec) ? s2_step_new : s2_step;
wire [15:0] s2_nsig  = s2_wrap ? s2_rsig : s2_sig_out;
wire        s2_rel = loop_pcb && rel_v[s2_ch];
wire [15:0] s2_env = s2_st[208:193];
wire        s2_dead = s2_rel && s2_env[15:8] == 8'd0;          // faded below -48 dB: stopped
wire [15:0] s2_vve = vv_q * s2_env[15:8];
wire [15:0] s2_env_new = (s2_rel && env_go) ? s2_env - {8'd0, s2_env[15:8]} : s2_env;

integer i;
always @(posedge clk) begin
	st_we <= 1'b0;
	ln_we <= 1'b0;
	tg_we <= 1'b0;
	pf_we <= 1'b0;
	lv_we <= 1'b0; rv_we <= 1'b0; vv_we <= 1'b0;
	kf_we <= 1'b0; fe_we <= 1'b0;
	kmul <= bendmul(loop_pcb ? wave[4] : 8'h00);
	kprod <= kfreq * kmul;
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
	// a line turns valid on the edge that writes it to ln_mem
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
		rel_v <= 32'd0;
		env_ctr <= 10'd0;
		env_go <= 1'b0;
	end else begin
		r3_v <= 1'b0;
		// line requests (demand and prefetch) go out when the fetch unit is free and no key-on is reading;
		// the slot is invalidated now and turns valid with the data (not a slot whose pf_mem entry is
		// written this clock: pf_q would read the old one)
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
							if (q_head[7:0] == 8'd2) rel_v[wave[14][4:0]] <= 1'b1;
							if (q_head[7:0] == 8'd0) begin
								kch <= wave[14][4:0];
								vo_wa <= wave[14][4:0];
								lv_we <= 1'b1; lv_wd <= wave[7];      // [207] left, [206] right: MAME has them the
								rv_we <= 1'b1; rv_wd <= wave[6];      // other way (Arcade-Eolith_MiSTer docs/QS1000_FEATURES.md)
								vv_we <= 1'b1; vv_wd <= wave[8];
								kbase <= {wave[1], wave[2], wave[3]};
								kstep <= 3'd0;
								es <= E_KON;
							end
						end
						5'h01, 5'h02, 5'h03, 5'h04, 5'h05, 5'h06, 5'h07, 5'h08, 5'h09, 5'h0a, 5'h0b, 5'h0c, 5'h0d: begin
							if (wave[17] == 8'd3) begin
								vo_wa <= wave[14][4:0];
								if (q_head[12:8] == 5'h07) begin lv_we <= 1'b1; lv_wd <= q_head[7:0]; end
								if (q_head[12:8] == 5'h06) begin rv_we <= 1'b1; rv_wd <= q_head[7:0]; end
								if (q_head[12:8] == 5'h08) begin vv_we <= 1'b1; vv_wd <= q_head[7:0]; end
								if (q_head[12:8] == 5'h04 && loop_pcb) begin
									b_ch <= wave[14][4:0];
									b_val <= q_head[7:0];
									es <= E_B1;
								end
							end else wave[q_head[12:8]] <= q_head[7:0];
						end
						default: if (q_head[12:8] <= 5'h11) wave[q_head[12:8]] <= q_head[7:0];
					endcase
				end
			end

			// ---- key-on: read the table entry (6 bytes at kbase) and the descriptor (9 bytes)
			E_KON: if (!f_busy && !rom_req) begin
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
					// descriptor (MAME start_voice): start = bytes 0-2, loop start = {byte 0 [7:4], bytes 3-4,
					// byte 5 [7:4]}, loop end = {byte 0 [7:4], byte 5 [3:0], bytes 6-7}
					st_we <= 1'b1;
					st_wa <= kch;
					rel_v[kch] <= 1'b0;
					kf_we <= 1'b1; kf_wa <= kch; kf_wd <= kfreq;
					fe_we <= 1'b1; fe_wa <= kch; fe_wd <= kprod[31:14];
					st_wd <= {10'd0, 16'hffff, 12'd0, 6'd0,                          // env, decoder state
					          kbuf[255 - 8*kbase[3:0] -: 4], kbuf[255 - 8*({1'b0, kbase[3:0]} + 5'd3) -: 16],
					          kbuf[255 - 8*({1'b0, kbase[3:0]} + 5'd5) -: 4],        // loop start
					          1'b1, kbuf[255 - 8*({1'b0, kbase[3:0]} + 5'd8) - 4],      // playing, adpcm (byte 8 bit 3)
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

			// ---- one tick: voices 0..31 through S0 (state read), S1 (line check), S2 (sample, write back);
			// S3-S5 below
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
						if (s2_stop || s2_dead) st_wd <= {s2_st[218:151], 1'b0, s2_st[149:0]};
						else begin
							st_wd <= {s2_rstep[6], s2_rsig[15:12], s2_nstep[6], s2_nsig[15:12],
							          s2_env_new, s2_rsig[11:0], s2_rstep[5:0], s2_lst, s2_st[150:149],
							          s2_nstep[5:0], s2_nsig[11:0],
							          s2_wrap ? {1'b0, s2_lst - s2_st[47:24]} - 25'd1 : (s2_adp && s2_dec) ? s2_na : s2_st[130:106],
							          s2_st[105:90], s2_accsum[17:0], s2_st[71:24], s2_wrap ? s2_lst : s2_addr_new};
							r3_v <= 1'b1;
							r3_adp <= s2_adp;
							r3_res <= s2_res;
							r3_vv <= s2_rel ? s2_vve[15:8] : vv_q;
							r3_lv <= lv_q;
							r3_rv <= rv_q;
						end
					end
					if (s2_ch == 5'd31) es <= E_OUT;
				end
			end
			// ---- a channel write of [204]: kf_q holds the voice's rate from E_B1's edge on
			E_B1: begin
				bmul <= bendmul(b_val);
				es <= E_B2;
			end
			E_B2: begin
				bprod <= kf_q * bmul;
				es <= E_B3;
			end
			E_B3: begin
				fe_we <= 1'b1; fe_wa <= b_ch; fe_wd <= bprod[31:14];
				es <= E_IDLE;
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
				env_go <= env_ctr == 10'd731;
				env_ctr <= (env_ctr == 10'd731) ? 10'd0 : env_ctr + 10'd1;
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
			// bal_pcb low: ADPCM x4, PCM x1 (MAME's gains, qs1000.cpp:484, :513). bal_pcb high, the PCB balance
			// (MAME_KLUDGES.md, Sound): ADPCM x8, PCM x4, the IMA music at the level the recording set for OKI's x2
			acc_l <= acc_l + (r5_adp ? (bal_pcb ? {{1{r5_pl[27]}}, r5_pl, 3'b0} : {{2{r5_pl[27]}}, r5_pl, 2'b0})
			                         : (bal_pcb ? {{2{r5_pl[27]}}, r5_pl, 2'b0} : {{4{r5_pl[27]}}, r5_pl}));
			acc_r <= acc_r + (r5_adp ? (bal_pcb ? {{1{r5_pr[27]}}, r5_pr, 3'b0} : {{2{r5_pr[27]}}, r5_pr, 2'b0})
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
