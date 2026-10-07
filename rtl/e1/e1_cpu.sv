// Hyperstone E1-16 / E1-32 CPU core, written from MAME's interpreter
// (src/devices/cpu/e132xs/e132xs.cpp, e132xsop.hxx, e1defs.h; BSD-3-Clause,
// copyright-holders Pierpaolo Prazzoli and the MAME team).
//
// One instruction at a time: fetch words, one execute cycle, then bus cycles for
// loads, stores and the frame/return spill loops. Behaviour follows the interpreter,
// including its quirks; each is marked "MAME:" where it is not what the ISA manual says.
//
// The bus is always 32 bits wide and big-endian. An E1-16 board puts a width adapter
// between this port and its 16-bit memory.
//
// Not implemented: power-down, the DSP extend opcodes other than the
// multiplies, floating point (the FP opcodes trap to their emulation code as in MAME).

module e1_cpu (
	input             clk,
	input             reset,
	input             cen,

	// bus: req held until ack. addr is the byte address; io=1 selects the I/O space,
	// where the glue uses addr >> 13 as the port. be is the byte-lane mask; wdata is
	// lane-positioned. rdata is the whole aligned dword.
	output reg        bus_req,
	output reg        bus_wr,
	output reg        bus_io,
	output reg        bus_ifetch,
	output reg [31:0] bus_addr,
	output reg [3:0]  bus_be,
	output reg [31:0] bus_wdata,
	input             bus_ack,
	input      [31:0] bus_rdata,

	input      [6:0]  irq_in,      // ISR bits: INT1..INT4, IO1..IO3
	output reg [6:0]  irq_ack,     // one-cycle pulse when the interrupt is taken
	input             pause,
	input             tick,        // one pulse per CPU clock (50 MHz): drives TR

	output reg        retire,      // one-cycle pulse after an instruction (or exception entry) completes
	output reg [31:0] retire_pc,   // address of that instruction
	output reg [31:0] retire_npc,  // architectural PC and SR after it (the next instruction may already
	output reg [31:0] retire_sr,   // have been fetched and its PC set when the pulse comes)

	output            dbg_rf_we,   // the local register file's write port, for probes
	output     [5:0]  dbg_rf_wa,
	output     [31:0] dbg_rf_wd
);

localparam [5:0] TRAP_RANGE = 6'd60;
localparam [5:0] TRAP_RESET = 6'd62;

localparam [4:0] ST_RESET  = 0,
                 ST_INT    = 1,
                 ST_FETCH  = 2,
                 ST_FWAIT  = 3,
                 ST_EXEC   = 4,
                 ST_MEM    = 5,
                 ST_MWAIT  = 6,
                 ST_MPOST  = 7,
                 ST_LOOP   = 8,
                 ST_DIV    = 9,
                 ST_DIVEND = 10,
                 ST_FRM    = 11,
                 ST_RD     = 12,
                 ST_MUL    = 13,
                 ST_MUL2   = 14;

reg [4:0]  state;

// architectural state
reg [31:0] pc, sr, delay_pc;
reg        delay_slot, delay_slot_taken;
reg [31:0] G [0:31];
// local registers live in e1_regram; a write lands one clock after commit_one, and the
// read ports forward it
reg [31:0] lS_r, lS1_r, lD_r, lD1_r, gS_r, gS1_r, gD_r, gD1_r, gM_r, gMD_r;
reg        l_we_n, l_we_r;
reg [5:0]  l_wa_n, l_wa_r;
reg [31:0] l_wd_n, l_wd_r;
wire [5:0] w_didx  = {2'b0, op[7:4]} + sr[30:25];
wire [5:0] w_didx1 = w_didx + 6'd1;
wire [5:0] w_sidx  = {2'b0, op[3:0]} + sr[30:25];
wire [5:0] w_sidx1 = w_sidx + 6'd1;
wire [31:0] g_dsel = G[op[7:4]];
wire [5:0] w_aidx;
wire [31:0] rS_raw, rS1_raw, rD_raw, rD1_raw, rA_raw;
e1_regram rf (.clk(clk), .we(l_we_r), .wa(l_wa_r), .wd(l_wd_r),
	.ra0(w_sidx), .ra1(w_sidx1), .ra2(w_didx), .ra3(w_didx1), .ra4(w_aidx),
	.rd0(rS_raw), .rd1(rS1_raw), .rd2(rD_raw), .rd3(rD1_raw), .rd4(rA_raw));
wire [31:0] lS  = (l_we_r && l_wa_r == w_sidx)  ? l_wd_r : rS_raw;
wire [31:0] lS1 = (l_we_r && l_wa_r == w_sidx1) ? l_wd_r : rS1_raw;
wire [31:0] lD  = (l_we_r && l_wa_r == w_didx)  ? l_wd_r : rD_raw;
wire [31:0] lD1 = (l_we_r && l_wa_r == w_didx1) ? l_wd_r : rD1_raw;
wire [31:0] lA  = (l_we_r && l_wa_r == w_aidx)  ? l_wd_r : rA_raw;
assign dbg_rf_we = l_we_r;
assign dbg_rf_wa = l_wa_r;
assign dbg_rf_wd = l_wd_r;
assign w_aidx = (state == ST_LOOP) ? G[18][7:2] : (op[9] ? lD_r[7:2] : gD_r[7:2]);
reg [31:0] trap_entry;
reg [1:0]  intblock;
reg        first_ins;
reg        fin_req;         // the instruction completes at the end of this cycle
reg [4:0]  nstate;
reg        frm_req, frm_fin, ret_pend, frm_body;
reg [1:0]  frm_kind;
reg [5:0]  frm_tn;
// Registers, never RAM: an instruction pushes up to two entries in one clock (CALL, double-register
// results). Quartus inferred wq_v as a one-write-port altsyncram and kept one of a CALL's two writes; on
// the board the return address was lost and the first RET jumped to 0 (docs/LESSONS_LEARNED.md).
(* ramstyle = "logic" *) reg        wq_g [0:4];
(* ramstyle = "logic" *) reg        wq_raw [0:4];
(* ramstyle = "logic" *) reg [5:0]  wq_i [0:4];
(* ramstyle = "logic" *) reg [31:0] wq_v [0:4];
reg [2:0]  wq_cnt, wq_rd;
reg        wq_busy0, retire_pending, wq_g0, did_commit;
reg [2:0]  wq_cnt_start;
// head entry as it stood at the start of the cycle (registers, not this cycle's pushes)
reg        hd_valid, hd_raw;
reg [5:0]  hd_i;
reg [31:0] hd_v;
reg [2:0]  wq_cnt0;
reg [31:0] fpc;
reg        wq_pcw, pcw_new, gw_new, late_cap;
// multiplier pipeline: operands registered in ST_EXEC, products registered in ST_MUL
reg [1:0]  mk;
reg        msg, m_dg;
reg [5:0]  m_di, m_di1;
reg [31:0] mA, mB;
reg signed [65:0] mp;
reg signed [31:0] p_ll, p_hh, p_lh, p_hl;
reg [31:0] tr_val;
reg [8:0]  tr_period, tr_cnt;
reg        tpr_pending;
reg [8:0]  tpr_next;
reg        timer_pend;

// current instruction
reg [15:0] op, e1, e2;
reg [1:0]  ilen, ilen0, ilen_x;
reg [15:0] op_x;
reg        fold_done, trace_will;           // halfwords fetched for this instruction (1..3)
reg [1:0]  fstage;         // 0 op, 1 e1, 2 e2
reg [31:0] ipc;            // address of the instruction

// instruction fetch cache: last dword read
reg        fc_valid;
// next-dword prefetch: filled while the bus would otherwise be idle
reg        pf_valid, pf_infl, pf_want, req_issued;
reg [31:0] pf_addr, pf_data;
reg [31:0] fc_addr, fc_data;

// bus job engine
reg        p_wr, p_io;
reg [1:0]  p_n, p_k;
reg [31:0] p_a0, p_a1, p_wd0, p_wd1;
reg [2:0]  p_kind;         // 0 word, 1 byte u, 2 byte s, 3 half u, 4 half s
reg [31:0] p_r0, p_r1;
reg        p_w0_en, p_w0_g, p_w1_en, p_w1_g;
reg [5:0]  p_w0_i, p_w1_i;
reg        p_b_en, p_b_g;
reg [5:0]  p_b_i;
reg [31:0] p_b_v;
reg        p_exc;
reg [1:0]  p_loop;         // 0 none, 1 frame spill, 2 ret fill
reg signed [7:0] lp_diff;
reg        lp_flag;

// divider
reg [63:0] dv_n, dv_q;
reg [32:0] dv_r;
reg [31:0] dv_d;
reg [6:0]  dv_cnt;
reg        dv_signed, dv_dneg;
reg        dv_dg;
reg [5:0]  dv_di;

integer    t_i;

//------------------------------------------------------------------
// helpers
//------------------------------------------------------------------
// register read as an instruction sees it: PC is the delayed-branch target inside a delay slot
function [31:0] rgv(input [4:0] i);
	case (i)
		5'd0: rgv = delay_slot ? delay_pc : pc;
		5'd1: rgv = sr;
		5'd25: rgv = {25'b0, irq_in};
		default: rgv = G[i];
	endcase
endfunction

function [31:0] rg(input [4:0] i);
	case (i)
		5'd0: rg = pc;
		5'd1: rg = sr;
		5'd25: rg = {25'b0, irq_in};
		default: rg = G[i];
	endcase
endfunction

function [5:0] fl_n(input [31:0] s);
	fl_n = (s[24:21] == 4'd0) ? 6'd16 : {2'b0, s[24:21]};
endfunction

function [31:0] trap_addr(input [5:0] tn);
	if (trap_entry == 32'hffffff00)
		trap_addr = {24'hffffff, tn, 2'b00} & 32'hffffffff | trap_entry;
	else
		trap_addr = {24'h0, (6'd63 - tn), 2'b00} | trap_entry;
endfunction

function [31:0] nz32(input [31:0] v);
	nz32 = {29'b0, v[31], (v == 32'd0), 1'b0};
endfunction

function [31:0] nz64(input [63:0] v);
	nz64 = {29'b0, v[63], (v == 64'd0), 1'b0};
endfunction

task set_fp(input [6:0] v);  sr[31:25] = v; endtask
task set_fl(input [3:0] v);  sr[24:21] = v; endtask

// set_global_register
task apply_global(input [4:0] i, input [31:0] v);
	begin
		case (i)
			5'd1: begin
				sr[15:0] = v[15:0];
				sr[6] = 1'b0;
			end
			5'd18, 5'd19: G[i] = {v[31:2], 2'b00};
			5'd21: begin
				G[i] = v;
				tpr_next = {1'b0, v[23:16]} + 9'd2;
				if (v[31]) tpr_pending = 1'b1;
				else begin tr_period = tpr_next; tr_cnt = 9'd0; tpr_pending = 1'b0; end
			end
			5'd22: begin
				if (G[i] != v) begin G[i] = v; timer_eval; end
			end
			5'd23: begin G[i] = v; tr_val = v; timer_eval; end
			5'd26: begin
				G[i] = v;
				timer_eval;
			end
			5'd25: ;
			5'd27: begin
				G[i] = v;
				case (v[14:12])
					3'd0: trap_entry = 32'h00000000;
					3'd1: trap_entry = 32'h40000000;
					3'd2: trap_entry = 32'h80000000;
					3'd3: trap_entry = 32'hc0000000;
					3'd7: trap_entry = 32'hffffff00;
					default: ;
				endcase
			end
			default: G[i] = v;
		endcase
	end
endtask

// MAME adjust_timer_interrupt: fire when TR has reached TCR and the interrupt is enabled
task timer_eval;
	begin
		if (!G[26][23] && ((tr_val - G[22]) & 32'h80000000) == 32'd0) timer_pend = 1'b1;
	end
endtask

// register writes go through a queue drained one entry per clock by commit_one, the
// only place the register arrays are written
// Each entry is written under a constant index. On the board, the first of two pushes in one clock
// (a CALL's return address, the reset state's L0) never reached the queue while the second did; the
// variable-index form (wq_v[wq_cnt] = v; wq_cnt = wq_cnt + 1, twice in one clock) simulates correctly
// (docs/LESSONS_LEARNED.md).
task wq_push(input wp_g, input wp_raw, input [5:0] wp_i, input [31:0] wp_v);
	begin
		if (wp_g && wp_i[4:0] == 5'd0) pcw_new = 1'b1;
		if (wp_g) gw_new = 1'b1;
		case (wq_cnt)
			3'd0: begin wq_g[0] = wp_g; wq_raw[0] = wp_raw; wq_i[0] = wp_i; wq_v[0] = wp_v; end
			3'd1: begin wq_g[1] = wp_g; wq_raw[1] = wp_raw; wq_i[1] = wp_i; wq_v[1] = wp_v; end
			3'd2: begin wq_g[2] = wp_g; wq_raw[2] = wp_raw; wq_i[2] = wp_i; wq_v[2] = wp_v; end
			3'd3: begin wq_g[3] = wp_g; wq_raw[3] = wp_raw; wq_i[3] = wp_i; wq_v[3] = wp_v; end
			3'd4: begin wq_g[4] = wp_g; wq_raw[4] = wp_raw; wq_i[4] = wp_i; wq_v[4] = wp_v; end
			default: ;
		endcase
`ifdef SIMULATION
		if (wq_cnt > 3'd4) $display("WQ_OVERFLOW cnt=%0d rd=%0d op=%04x pc=%08x i=%0d g=%0d", wq_cnt, wq_rd, op, ipc, wp_i, wp_g);
`endif
		wq_cnt = wq_cnt + 3'd1;
	end
endtask

// set_global_register semantics on a destination register
task write_dst(input g, input [5:0] i, input [31:0] v);
	begin
		// a PC write takes effect in this cycle, so the queue never changes PC
		if (g && i[4:0] == 5'd0) pc = {v[31:1], 1'b0};
		else begin
			// MAME: a user-mode write that sets L is a privilege error (checked here, applied at commit)
			if (g && i[4:0] == 5'd1 && !sr[18] && !sr[15] && v[15]) req_exc(TRAP_RANGE);
			wq_push(g, 1'b0, i, v);
		end
	end
endtask

// raw write: no side effects (MAME writes global_regs[] directly in several places)
task write_raw(input g, input [5:0] i, input [31:0] v);
	begin
		wq_push(g, 1'b1, i, v);
	end
endtask

// queue head, local register: written into the register file at the start of the cycle
task commit_loc;
	begin
		if (wq_rd < wq_cnt && !wq_g[wq_rd]) begin
			l_we_n = 1'b1; l_wa_n = wq_i[wq_rd]; l_wd_n = wq_v[wq_rd];
			wq_rd = wq_rd + 3'd1;
			did_commit = 1'b1;
		end
	end
endtask

// queue head, global register: applied at the end of the cycle, so the instruction logic
// of that cycle never sees it and the SR, timer and trap-entry updates stay off its paths
task commit_glob;
	begin
		if (!did_commit && hd_valid) begin
			if (hd_raw) G[hd_i[4:0]] = hd_v;   // raw writes never target PC or SR
			else apply_global(hd_i[4:0], hd_v);
			wq_rd = wq_rd + 3'd1;
		end
	end
endtask

// exception, trap and interrupt entry are requests, applied by ST_FRM
task req_exc(input [5:0] tn);
	begin frm_req = 1'b1; frm_body = 1'b1; frm_kind = 2'd0; frm_tn = tn; frm_fin = 1'b1; end
endtask

task req_trap(input [5:0] tn);
	begin frm_req = 1'b1; frm_body = 1'b1; frm_kind = 2'd1; frm_tn = tn; frm_fin = 1'b1; end
endtask

task req_int(input [5:0] tn);
	begin frm_req = 1'b1; frm_kind = 2'd2; frm_tn = tn; frm_fin = 1'b0; end
endtask

// end-of-instruction update from execute_run: ILC and P, then the trace trap
task post_instr;
	begin
		if (((op & 16'hfef0) != 16'h0400) || ((op & 16'h010e) == 16'h0000)) begin
			sr[20:19] = ilen_x;
			sr[17] = 1'b1;
		end
		if (sr[16] && sr[17] && !delay_slot) begin
			delay_slot_taken = 1'b0;
			frm_req = 1'b1; frm_body = 1'b1; frm_kind = 2'd0; frm_tn = 6'd57; frm_fin = 1'b0;
		end
	end
endtask

// execute_exception / execute_trap / execute_int, one instance
task apply_frame;
	reg [7:0]  r;
	reg [31:0] oldsr, addr;
	reg [3:0]  nfl;
	begin
		addr = trap_addr(frm_tn);
		r = {1'b0, sr[31:25]} + {2'b0, fl_n(sr)};
		case (frm_kind)
			2'd0: begin
				if (!delay_slot_taken) sr[20:19] = ilen_x;
				else pc = delay_pc - {30'b0, ilen_x};   // MAME: subtracts the halfword count, not bytes
				// MAME: RET does not set P
				if (((op_x & 16'hfef0) != 16'h0400) || ((op_x & 16'h010e) == 16'h0000)) sr[17] = 1'b1;
				nfl = 4'd2;
			end
			2'd1: begin sr[20:19] = ilen_x; nfl = 4'd6; end
			default: nfl = 4'd2;
		endcase
		oldsr = sr;
		sr[24:21] = nfl;
		sr[31:25] = r[6:0];
`ifdef E1_DEBUG
		$display("FRM kind=%0d r=%0d pc=%08x sr=%08x oldsr=%08x", frm_kind, r[5:0], pc, sr, oldsr);
`endif
		wq_push(1'b0, 1'b0, r[5:0], {pc[31:1], 1'b0} | {31'b0, sr[18]});
		wq_push(1'b0, 1'b0, r[5:0] + 6'd1, oldsr);
		sr[4] = 1'b0; sr[16] = 1'b0;
		sr[15] = 1'b1; sr[18] = 1'b1;
		if (frm_kind == 2'd2) sr[7] = 1'b1;
		pc = addr;
	end
endtask

// sized lane extraction for loads
function [31:0] lane_ext(input [31:0] rd, input [31:0] a, input [2:0] kind);
	reg [7:0]  b;
	reg [15:0] h;
	begin
		b = rd >> (8 * (3 - a[1:0]));
		h = a[1] ? rd[15:0] : rd[31:16];
		case (kind)
			3'd1: lane_ext = {24'b0, b};
			3'd2: lane_ext = {{24{b[7]}}, b};
			3'd3: lane_ext = {16'b0, h};
			3'd4: lane_ext = {{16{h[15]}}, h};
			default: lane_ext = rd;
		endcase
	end
endfunction

function [3:0] be_of(input [31:0] a, input [2:0] kind);
	case (kind)
		3'd1, 3'd2: be_of = 4'b1000 >> a[1:0];
		3'd3, 3'd4: be_of = a[1] ? 4'b0011 : 4'b1100;
		default:    be_of = 4'b1111;
	endcase
endfunction

function [31:0] wd_of(input [31:0] a, input [2:0] kind, input [31:0] v);
	case (kind)
		3'd1, 3'd2: wd_of = {4{v[7:0]}};
		3'd3, 3'd4: wd_of = {2{v[15:0]}};
		default:    wd_of = v;
	endcase
endfunction

// does the instruction have a first extension word?
function need_e1(input [15:0] o);
	reg [7:0] c;
	begin
		c = o[15:8];
		if ((c >= 8'h10 && c <= 8'h1f) || (c >= 8'h90 && c <= 8'h9f) ||
		    c == 8'hee || c == 8'hef || c == 8'hce)
			need_e1 = 1'b1;
		else if (c >= 8'h60 && c <= 8'h7f && c[0])
			need_e1 = (o[3:0] == 4'd1 || o[3:0] == 4'd2 || o[3:0] == 4'd3);
		else if (((c >= 8'he0 && c <= 8'hec) || (c >= 8'hf0 && c <= 8'hfc)) && o[7])
			need_e1 = 1'b1;
		else
			need_e1 = 1'b0;
	end
endfunction

// MAME: the interpreter sets ILC from this table once, before the first instruction after
// reset (get_instruction_length); the long-branch and 0xb0-0xbc entries are what MAME does
function [1:0] first_ilc(input [15:0] o, input [15:0] w1);
	reg [7:0] c;
	begin
		c = o[15:8];
		if ((c >= 8'h10 && c <= 8'h1f) || (c >= 8'h90 && c <= 8'h9f) || c == 8'hee || c == 8'hef)
			first_ilc = w1[15] ? 2'd3 : 2'd2;
		else if (c >= 8'h60 && c <= 8'h7f && c[0])
			first_ilc = (o[3:0] == 4'd1) ? 2'd3 : ((o[3:0] == 4'd2 || o[3:0] == 4'd3) ? 2'd2 : 2'd1);
		else if (c >= 8'hb0 && c <= 8'hbc)
			first_ilc = o[7] ? 2'd2 : 2'd1;
		else if (c == 8'hce)
			first_ilc = 2'd2;
		else
			first_ilc = 2'd1;
	end
endfunction

function need_e2(input [15:0] o, input [15:0] w1);
	reg [7:0] c;
	begin
		c = o[15:8];
		if ((c >= 8'h10 && c <= 8'h1f) || (c >= 8'h90 && c <= 8'h9f) || c == 8'hee || c == 8'hef)
			need_e2 = w1[15];
		else if (c >= 8'h60 && c <= 8'h7f && c[0])
			need_e2 = (o[3:0] == 4'd1);
		else
			need_e2 = 1'b0;
	end
endfunction

// arithmetic / logical right shifts as functions, so the signedness of the
// expression cannot turn >>> into >> through a mixed-sign conditional
function [63:0] shr64(input [63:0] v, input [4:0] n, input arith);
	reg signed [63:0] sv;
	begin
		sv = v;
		if (arith) begin sv = sv >>> n; shr64 = sv; end
		else shr64 = v >> n;
	end
endfunction

function [31:0] shr32(input [31:0] v, input [4:0] n, input arith);
	reg signed [31:0] sv;
	begin
		sv = v;
		if (arith) begin sv = sv >>> n; shr32 = sv; end
		else shr32 = v >> n;
	end
endfunction

function [31:0] clz32(input [31:0] v);
	integer k;
	reg done;
	begin
		clz32 = 32'd32; done = 1'b0;
		for (k = 31; k >= 0; k = k - 1)
			if (!done && v[k]) begin clz32 = 31 - k; done = 1'b1; end
	end
endfunction

function [63:0] smul(input [31:0] a, input [31:0] b);
	reg signed [31:0] sa, sb;
	reg signed [63:0] p;
	begin
		sa = a; sb = b; p = sa * sb; smul = p;
	end
endfunction

// RET: how many register-file lines to fill back from the stack
task ret_loop_start;
	reg signed [8:0] ds;
	begin
		ds = $signed({2'b0, sr[31:25]}) - $signed({2'b0, G[18][8:2]});
		lp_diff = {ds[6], ds[6:0]};
		if (lp_diff < 0) begin
			p_loop <= 2'd2; nstate = ST_LOOP; fin_req = 1'b0;
		end else begin
			fin_req = 1'b1; nstate = ST_INT;
		end
	end
endtask

// fetch one halfword at fpc: from the cached dword in this cycle, else a bus read
task fetch_word;
	reg [31:0] w;
	begin
		if (fc_valid && fc_addr == {fpc[31:2], 2'b00}) begin
			w = fpc[1] ? {16'b0, fc_data[15:0]} : {16'b0, fc_data[31:16]};
			consume_word(w[15:0]);
		end else if (pf_valid && pf_addr == {fpc[31:2], 2'b00}) begin
			// the prefetched dword becomes the current one and the next is wanted
			w = fpc[1] ? {16'b0, pf_data[15:0]} : {16'b0, pf_data[31:16]};
			fc_valid <= 1'b1; fc_addr <= pf_addr; fc_data <= pf_data;
			pf_valid <= 1'b0; pf_want = 1'b1; pf_addr = pf_addr + 32'd4;
			consume_word(w[15:0]);
		end else if (pf_infl) begin
			// the prefetch owns the bus; try again next cycle
			nstate = ST_FETCH;
		end else begin
			bus_req <= 1'b1; bus_wr <= 1'b0; bus_io <= 1'b0; bus_ifetch <= 1'b1;
			bus_addr <= {fpc[31:2], 2'b00}; bus_be <= 4'b1111; bus_wdata <= 32'd0;
			req_issued = 1'b1;
			nstate = ST_FWAIT;
		end
	end
endtask

// start the next instruction's fetch in the cycle the instruction ends (EXEC or the last MWAIT),
// when nothing can still redirect it. Kept in the instruction's own branch so the commit and
// frame logic of other states are not in this cycle's fetch-address path.
task fold_fetch;
	begin
		if (fin_req) begin
			fpc = pc;
			ipc <= pc;
			ilen = 2'd1;
			fstage = 2'd0;
			fold_done = 1'b1;
			fetch_word;
		end
	end
endtask

task consume_word(input [15:0] w);
	begin
`ifdef E1_DEBUG
		$display("consume stage=%0d fpc=%08x w=%04x", fstage, fpc, w);
`endif
		fpc = fpc + 32'd2;
		case (fstage)
			2'd0: begin
				op <= w;
				if (need_e1(w)) begin fstage = 2'd1; ilen = 2'd2; nstate = ST_FETCH; end
				else nstate = ST_RD;
			end
			2'd1: begin
				e1 <= w;
				if (need_e2(op, w)) begin fstage = 2'd2; ilen = 2'd3; nstate = ST_FETCH; end
				else nstate = ST_RD;
			end
			default: begin
				e2 <= w;
				nstate = ST_RD;
			end
		endcase
	end
endtask

//------------------------------------------------------------------
// interrupts: returns 1 and takes the interrupt if one is pending (check_interrupts)
//------------------------------------------------------------------
task check_interrupts(output taken);
	reg [31:0] fcr;
	reg [1:0]  tp;
	reg        tm;
	begin
		fcr = G[26];
		taken = 1'b1;
		tp = fcr[21:20];
		tm = timer_pend && !fcr[23];
		if (sr[15]) taken = 1'b0;
		else if (irq_in[6] && (fcr & 32'h00000500) == 32'h00000400) begin irq_ack[6] <= 1'b1; req_int(6'd54); end
		else if (tm && tp == 2'd3) begin timer_pend = 1'b0; req_int(6'd55); end
		else if (irq_in[0] && !fcr[28]) begin irq_ack[0] <= 1'b1; req_int(6'd53); end
		else if (tm && tp == 2'd2) begin timer_pend = 1'b0; req_int(6'd55); end
		else if (irq_in[1] && !fcr[29]) begin irq_ack[1] <= 1'b1; req_int(6'd52); end
		else if (tm && tp == 2'd1) begin timer_pend = 1'b0; req_int(6'd55); end
		else if (irq_in[2] && !fcr[30]) begin irq_ack[2] <= 1'b1; req_int(6'd51); end
		else if (tm && tp == 2'd0) begin timer_pend = 1'b0; req_int(6'd55); end
		else if (irq_in[3] && !fcr[31]) begin irq_ack[3] <= 1'b1; req_int(6'd50); end
		else if (irq_in[4] && (fcr & 32'h00000005) == 32'h00000004) begin irq_ack[4] <= 1'b1; req_int(6'd49); end
		else if (irq_in[5] && (fcr & 32'h00000050) == 32'h00000040) begin irq_ack[5] <= 1'b1; req_int(6'd48); end
		else taken = 1'b0;
	end
endtask

//------------------------------------------------------------------
// main FSM
//------------------------------------------------------------------
// temporaries for the execute cycle
reg [7:0]  opc;
reg [3:0]  dc, sc;
reg        dl, sl;
reg [6:0]  fp;
reg [5:0]  didx, sidx, didx1, sidx1;
reg [31:0] sreg, dreg, sregf, dregf, sregc;
reg [31:0] imm, res, tmp32, tmp32b;
reg [32:0] t33;
reg [63:0] t64;
reg [31:0] nsr_mask;
reg        cond, took;
reg [31:0] xs, extra_s, extra_u, ea;
reg [1:0]  subt;
reg        longf;
reg [4:0]  n5;
reg [5:0]  nimm;
reg [31:0] ofs;
reg [63:0] dw;
reg [31:0] hi, lo, msk, tmpv;
reg [7:0]  r8;
reg signed [8:0] dsel;
reg [7:0]  func_hi;
reg        e_ok;
reg        nodcp;

wire [31:0] bus_rd_lane = bus_rdata;

always @(posedge clk) begin
	retire <= 1'b0;
irq_ack <= 7'd0;

	if (reset) begin
state <= ST_RESET;
		bus_req <= 1'b0;
		fc_valid <= 1'b0;
		pf_valid <= 1'b0; pf_infl = 1'b0; pf_want = 1'b0;
		// the queue is read before ST_RESET's code runs in the first clock out of reset, so it is empty
		// here, not only after ST_RESET: an initial value is not a power-up value in Quartus (the board
		// committed junk writes and lost a register, docs/LESSONS_LEARNED.md)
		wq_cnt = 3'd0; wq_rd = 3'd0; ret_pend = 1'b0; retire_pending = 1'b0; late_cap = 1'b0;
		l_we_r <= 1'b0;
	end else if (cen && !pause) begin
nstate = state;
fin_req = 1'b0;
frm_req = 1'b0;
frm_body = 1'b0;
fold_done = 1'b0;
ilen0 = ilen;
pcw_new = 1'b0;
gw_new = 1'b0;
req_issued = 1'b0;
if (pf_infl && bus_req && bus_ack) begin
	pf_data <= bus_rdata; pf_valid <= 1'b1; pf_infl = 1'b0; bus_req <= 1'b0;
end
// one queued register write per clock, applied at the start of the cycle that follows
// the instruction; the instruction's own cycle only fills the queue
wq_busy0 = (wq_cnt != 3'd0);
wq_cnt0 = wq_cnt;
wq_g0 = (wq_rd < wq_cnt) ? wq_g[wq_rd] : 1'b0;
l_we_n = 1'b0;
did_commit = 1'b0;
commit_loc;
wq_cnt_start = wq_cnt;      // entries pushed in this cycle are committed from the next one
if (wq_rd >= wq_cnt) begin wq_rd = 3'd0; wq_cnt = 3'd0; wq_cnt_start = 3'd0; end
hd_valid = (wq_rd < wq_cnt_start) && wq_g[wq_rd];
hd_raw = wq_raw[wq_rd]; hd_i = wq_i[wq_rd]; hd_v = wq_v[wq_rd];
wq_pcw = 1'b0;
for (t_i = 0; t_i < 5; t_i = t_i + 1)
	if (t_i >= wq_rd && t_i < wq_cnt && wq_g[t_i] && wq_i[t_i][4:0] == 5'd0) wq_pcw = 1'b1;
if (tick && state != ST_RESET) begin
			if (tr_cnt + 9'd1 >= tr_period) begin
				tr_cnt = 9'd0;
				if (tpr_pending) begin tr_period = tpr_next; tpr_pending = 1'b0; end
				tr_val = tr_val + 32'd1;
				if (tr_val == G[22] && !G[26][23]) timer_pend = 1'b1;
			end else tr_cnt = tr_cnt + 9'd1;
		end
		case (state)
		//----------------------------------------------------------
		ST_RESET: begin
			for (t_i = 0; t_i < 32; t_i = t_i + 1) G[t_i] = 32'd0;
			wq_cnt = 3'd0; wq_rd = 3'd0; ret_pend = 1'b0; retire_pending = 1'b0; late_cap = 1'b0;
			trap_entry = 32'hffffff00;
			G[20] = 32'hffffffff;      // BCR
			G[27] = 32'hffffffff;      // MCR
			G[26] = 32'hffffffff;      // FCR
			G[21] = 32'h0c000000;      // TPR
			tr_val = 32'd0; tr_period = 9'd2; tr_cnt = 9'd0; tpr_pending = 1'b0; timer_pend = 1'b0;
			sr = 32'd0;
			pc = trap_addr(TRAP_RESET);
			set_fp(7'd0); set_fl(4'd2);
			sr[4] = 1'b0; sr[16] = 1'b0; sr[15] = 1'b1; sr[18] = 1'b1;
			sr[20:19] = 2'd1;
			wq_push(1'b0, 1'b0, 6'd0, {pc[31:1], 1'b0} | {31'b0, sr[18]});
wq_push(1'b0, 1'b0, 6'd1, sr);
			delay_slot = 1'b0; delay_slot_taken = 1'b0; delay_pc = 32'd0;
			intblock = 2'd0;
			first_ins = 1'b1;
			p_loop <= 2'd0;
			nstate = ST_INT;
		end

		//----------------------------------------------------------
		// instruction fetch: stage 0 starts here (interrupts are sampled in ST_RD, so the
		// fetch does not wait for the previous instruction's register writes)
		ST_INT: if (wq_pcw) begin
			// a pending write to PC decides where the fetch starts
			nstate = ST_INT;
		end else begin
			fpc = pc;
			ipc <= pc;
			ilen = 2'd1;
			fstage = 2'd0;
			fetch_word;
		end

		ST_FETCH: fetch_word;

		ST_FWAIT: begin
			if (bus_req && bus_ack) begin
				bus_req <= 1'b0;
				fc_valid <= 1'b1; fc_addr <= bus_addr; fc_data <= bus_rdata;
				pf_valid <= 1'b0; pf_want = 1'b1; pf_addr = bus_addr + 32'd4;
				tmp32 = fpc[1] ? {16'b0, bus_rdata[15:0]} : {16'b0, bus_rdata[31:16]};
				consume_word(tmp32[15:0]);
			end
		end

		//----------------------------------------------------------
		// operand read: register file and global registers into plain registers, so the
		// execute cycle starts from flip-flops. Earlier writes must have reached the arrays.
		// The interrupt is sampled here, once, when the instruction goes on.
		ST_RD: if (wq_cnt0 > 3'd1 || (wq_cnt0 == 3'd1 && wq_g0)) begin
			// one pending local write is bypassed below; anything else waits
			nstate = ST_RD;
		end else begin
			if (intblock <= 2'd1) begin
				intblock = 2'd0;
				check_interrupts(took);
			end else begin
				intblock = intblock - 2'd1;
			end
			if (!frm_req) begin
				pc = fpc;
				op_x <= op; ilen_x <= ilen;
				if (first_ins) begin sr[20:19] = first_ilc(op, e1); first_ins = 1'b0; end
				lS_r  <= (l_we_n && l_wa_n == w_sidx)  ? l_wd_n : lS;
				lS1_r <= (l_we_n && l_wa_n == w_sidx1) ? l_wd_n : lS1;
				lD_r  <= (l_we_n && l_wa_n == w_didx)  ? l_wd_n : lD;
				lD1_r <= (l_we_n && l_wa_n == w_didx1) ? l_wd_n : lD1;
				gS_r  <= rgv({1'b0, op[3:0]});
				gS1_r <= rgv({1'b0, op[3:0]} + 5'd1);
				gD_r  <= rgv({1'b0, op[7:4]});
				gD1_r <= rgv({1'b0, op[7:4]} + 5'd1);
				gM_r  <= rgv({1'b0, op[3:0]} + (sr[5] ? 5'd16 : 5'd0));
				gMD_r <= rgv({1'b0, op[7:4]} + (sr[5] ? 5'd16 : 5'd0));
				nstate = ST_EXEC;
			end
		end

		ST_EXEC: if (pf_infl && ((op[15:8] >= 8'h90 && op[15:8] <= 8'h9f) || (op[15:8] >= 8'hd0 && op[15:8] <= 8'hdf))) begin
			nstate = ST_EXEC;
		end else begin
			fin_req = 1'b1;
nstate = ST_INT;
			opc = op[15:8]; dc = op[7:4]; sc = op[3:0];
			dl = opc[1]; sl = opc[0];
			// check_delay_pc, for every instruction except the delayed branches and the
			// reserved opcodes, which leave it alone
			nodcp = (opc >= 8'he0 && opc <= 8'hec) || opc == 8'h8c || opc == 8'h8d ||
			        (opc >= 8'hac && opc <= 8'haf) || opc == 8'hcf;
			if (!nodcp) begin
				if (!delay_slot) delay_slot_taken = 1'b0;
				else begin
					tmp32 = pc; pc = delay_pc; delay_pc = tmp32;
					delay_slot = 1'b0; delay_slot_taken = 1'b1;
				end
			end
			fp = sr[31:25];
			didx = {2'b0, dc} + fp[5:0];  didx1 = didx + 6'd1;
			sidx = {2'b0, sc} + fp[5:0];  sidx1 = sidx + 6'd1;
			sreg = sl ? lS_r : gS_r;
			dreg = dl ? lD_r : gD_r;
			sregc = (!sl && sc == 4'd1) ? {31'b0, sr[0]} : sreg;
			
casez (opc)
			//------------------------------------------------ chk
			8'h00, 8'h01, 8'h02, 8'h03: begin
				if (!sl && sc == 4'd1) begin
					if (dreg == 32'd0) req_exc(TRAP_RANGE);
				end else begin
					cond = (!sl && sc == 4'd0) ? (dreg >= sreg) : (dreg > sreg);
					if (cond) req_exc(TRAP_RANGE);
				end
			end
			//------------------------------------------------ movd
			8'h04, 8'h05, 8'h06, 8'h07: begin
				sregf = sl ? lS1_r : gS1_r;
				if (!dl && dc == 4'd0) begin
					if (!sl && sc < 4'd2) begin
						// MAME: RET with PC/SR source does nothing
					end else begin
						pc = {sreg[31:1], 1'b0};
						tmpv = sr;
						sr = (sregf & ~32'h001c0000) | {13'b0, sreg[0], 18'b0};
						// privilege checks (old S/L from tmpv)
						if ((!tmpv[18] && sr[18]) || (!sr[18] && !tmpv[15] && sr[15])) req_exc(TRAP_RANGE);
						if (frm_req) begin
							// MAME: the loop runs after the exception entry, with the new frame pointer
							ret_pend = 1'b1; fin_req = 1'b0;
						end else begin
							ret_loop_start;
						end
					end
				end else if (!sl && sc == 4'd1) begin
					sr[1] = 1'b1; sr[2] = 1'b0;
					write_dst(!dl, dl ? didx : {2'b0, dc}, 32'd0);
					write_dst(!dl, dl ? didx1 : ({2'b0, dc} + 6'd1), 32'd0);
				end else begin
					sr[2:1] = 2'b00;
					if (sreg == 32'd0 && sregf == 32'd0) sr[1] = 1'b1;
					sr[2] = sreg[31];
					write_dst(!dl, dl ? didx : {2'b0, dc}, sreg);
					write_dst(!dl, dl ? didx1 : ({2'b0, dc} + 6'd1), sregf);
				end
			end
			//------------------------------------------------ divu / divs
			8'h08, 8'h09, 8'h0a, 8'h0b, 8'h0c, 8'h0d, 8'h0e, 8'h0f: begin
				// MAME: same-register and PC/SR sources do nothing
				if (((sl == dl) && ((sl ? sidx : {2'b0, sc}) == (dl ? didx : {2'b0, dc}) ||
				                   (sl ? sidx : {2'b0, sc}) == (dl ? didx1 : ({2'b0, dc} + 6'd1)))) ||
				    (!sl && sc < 4'd2)) begin
				end else begin
					dregf = dl ? lD1_r : gD1_r;
					dw = {dreg, dregf};
					dv_signed = opc[2];
					if (sreg == 32'd0 || (opc[2] && dw[63])) begin
						sr[3] = 1'b1;
						req_exc(TRAP_RANGE);
					end else begin
						dv_n <= dw; dv_q <= 64'd0; dv_r <= 33'd0; dv_cnt <= 7'd0;
						dv_dneg <= opc[2] && sreg[31];
						dv_d <= (opc[2] && sreg[31]) ? (~sreg + 32'd1) : sreg;
						dv_dg <= !dl; dv_di <= dl ? didx : {2'b0, dc};
						nstate = ST_DIV;
						
						fin_req = 1'b0;
					end
				end
			end
			//------------------------------------------------ xm
			8'h10, 8'h11, 8'h12, 8'h13: begin
				longf = e1[15];
				extra_u = longf ? {4'b0, e1[11:0], e2} : {20'b0, e1[11:0]};
				subt = e1[13:12];
				if ((!sl && sc == 4'd1) || (!dl && dc < 4'd2)) begin
				end else begin
					write_raw(!dl, dl ? didx : {2'b0, dc}, sreg << e1[13:12]);
					if (!e1[14]) begin
						cond = (!sl && sc == 4'd0) ? (sreg >= extra_u) : (sreg > extra_u);
						if (cond) req_exc(TRAP_RANGE);
					end
				end
			end
			//------------------------------------------------ mask
			8'h14, 8'h15, 8'h16, 8'h17: begin
				imm = e1[15] ? ({e1[13:0], e2} | (e1[14] ? 32'hc0000000 : 32'h0))
				             : ({18'b0, e1[13:0]} | (e1[14] ? 32'hffffc000 : 32'h0));
				res = sreg & imm;
				sr[1] = (res == 32'd0);
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
			end
			//------------------------------------------------ sum
			8'h18, 8'h19, 8'h1a, 8'h1b: begin
				imm = e1[15] ? ({e1[13:0], e2} | (e1[14] ? 32'hc0000000 : 32'h0))
				             : ({18'b0, e1[13:0]} | (e1[14] ? 32'hffffc000 : 32'h0));
				t33 = {1'b0, sregc} + {1'b0, imm};
				sr[3:0] = 4'b0000;
				sr[0] = t33[32];
				sr[3] = (sregc[31] ^ t33[31]) & (imm[31] ^ t33[31]);
				res = t33[31:0];
				sr[2:1] = {res[31], res == 32'd0};
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
			end
			//------------------------------------------------ sums
			8'h1c, 8'h1d, 8'h1e, 8'h1f: begin
				imm = e1[15] ? ({e1[13:0], e2} | (e1[14] ? 32'hc0000000 : 32'h0))
				             : ({18'b0, e1[13:0]} | (e1[14] ? 32'hffffc000 : 32'h0));
				t33 = {1'b0, sregc} + {1'b0, imm};
				sr[3:1] = 3'b000;
				sr[3] = (sregc[31] ^ t33[31]) & (imm[31] ^ t33[31]);
				res = t33[31:0];
				sr[2:1] = {res[31], res == 32'd0};
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
				// MAME: tests src_code against SR even for a local source
				if (sr[3] && (sl ? sidx : {2'b0, sc}) != 6'd1) req_exc(TRAP_RANGE);
			end
			//------------------------------------------------ cmp
			8'h20, 8'h21, 8'h22, 8'h23: begin
				t33 = {1'b0, dreg} - {1'b0, sregc};
				sr[3:0] = 4'b0000;
				sr[3] = (t33[31] ^ dreg[31]) & (dreg[31] ^ sregc[31]);
				if (dreg < sregc) sr[0] = 1'b1;
				else if (dreg == sregc) sr[1] = 1'b1;
				if ($signed(dreg) < $signed(sregc)) sr[2] = 1'b1;
			end
			//------------------------------------------------ mov
			8'h24, 8'h25, 8'h26, 8'h27: begin
				tmpv = sr;
				sr[5] = 1'b0;
				if (!dl && tmpv[5] && !sr[18]) req_exc(TRAP_RANGE);
				else begin
					if (!sl) begin
						// MAME: BCR, TPR, FCR and MCR read as zero
						tmp32b = {1'b0, sc} + (tmpv[5] ? 5'd16 : 5'd0);
						case (tmp32b[4:0])
							5'd20, 5'd21, 5'd26, 5'd27: res = 32'd0;
							5'd23: res = tr_val;
							default: res = gM_r;
						endcase
					end else res = lS_r;
					sr[2:1] = {res[31], res == 32'd0};
					if (!dl) begin
						tmp32b = {1'b0, dc} + (tmpv[5] ? 5'd16 : 5'd0);
						write_dst(1'b1, {1'b0, tmp32b[4:0]}, res);
						if (tmp32b[4:0] == 5'd0) sr[4] = 1'b0;
					end else wq_push(1'b0, 1'b0, didx, res);
				end
			end
			//------------------------------------------------ add
			8'h28, 8'h29, 8'h2a, 8'h2b: begin
				t33 = {1'b0, sregc} + {1'b0, dreg};
				sr[3:0] = 4'b0000;
				sr[0] = t33[32];
				sr[3] = (sregc[31] ^ t33[31]) & (dreg[31] ^ t33[31]);
				res = t33[31:0];
				sr[2:1] = {res[31], res == 32'd0};
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
				if (!dl && dc == 4'd0) sr[4] = 1'b0;
			end
			//------------------------------------------------ adds
			8'h2c, 8'h2d, 8'h2e, 8'h2f: begin
				t33 = {1'b0, sregc} + {1'b0, dreg};
				sr[3:1] = 3'b000;
				sr[3] = (sregc[31] ^ t33[31]) & (dreg[31] ^ t33[31]);
				res = t33[31:0];
				sr[2:1] = {res[31], res == 32'd0};
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
				if (sr[3]) req_exc(TRAP_RANGE);
			end
			//------------------------------------------------ cmpb
			8'h30, 8'h31, 8'h32, 8'h33: begin
				sr[1] = ((dreg & sreg) == 32'd0);
			end
			//------------------------------------------------ andn, or, xor, and
			8'h34, 8'h35, 8'h36, 8'h37,
			8'h38, 8'h39, 8'h3a, 8'h3b,
			8'h3c, 8'h3d, 8'h3e, 8'h3f,
			8'h54, 8'h55, 8'h56, 8'h57: begin
				case (opc[7:2])
					6'b001101: res = dreg & ~sreg;
					6'b001110: res = dreg | sreg;
					6'b001111: res = dreg ^ sreg;
					default:   res = dreg & sreg;
				endcase
				sr[1] = (res == 32'd0);
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
			end
			//------------------------------------------------ subc
			8'h40, 8'h41, 8'h42, 8'h43: begin
				tmp32 = (!sl && sc == 4'd1) ? 32'd0 : sreg;
				tmp32b = tmp32 + {31'b0, sr[0]};
				t33 = {1'b0, dreg} - {1'b0, tmp32} - {32'b0, sr[0]};
				tmpv = sr;
				sr[3:0] = 4'b0000;
				sr[3] = (t33[31] ^ dreg[31]) & (dreg[31] ^ tmp32b[31]);
				sr[0] = t33[32];
				res = dreg - tmp32b;
				if (tmpv[1] && res == 32'd0) sr[1] = 1'b1;
				sr[2] = res[31];
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
			end
			//------------------------------------------------ not
			8'h44, 8'h45, 8'h46, 8'h47: begin
				res = ~sreg;
				sr[1] = (res == 32'd0);
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
			end
			//------------------------------------------------ sub
			8'h48, 8'h49, 8'h4a, 8'h4b: begin
				t33 = {1'b0, dreg} - {1'b0, sregc};
				sr[3:0] = 4'b0000;
				sr[0] = t33[32];
				sr[3] = (t33[31] ^ dreg[31]) & (dreg[31] ^ sregc[31]);
				res = t33[31:0];
				sr[2:1] = {res[31], res == 32'd0};
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
				if (!dl && dc == 4'd0) sr[4] = 1'b0;
			end
			//------------------------------------------------ subs
			8'h4c, 8'h4d, 8'h4e, 8'h4f: begin
				t33 = {1'b0, dreg} - {1'b0, sregc};
				sr[3:1] = 3'b000;
				sr[3] = (t33[31] ^ dreg[31]) & (dreg[31] ^ sregc[31]);
				res = t33[31:0];
				sr[2:1] = {res[31], res == 32'd0};
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
				if (sr[3]) req_exc(TRAP_RANGE);
			end
			//------------------------------------------------ addc
			8'h50, 8'h51, 8'h52, 8'h53: begin
				tmpv = sr;
				sr[3:0] = 4'b0000;
				if (!sl && sc == 4'd1) begin
					t33 = {1'b0, dreg} + {32'b0, tmpv[0]};
					sr[3] = (dreg[31] ^ t33[31]) & t33[31];
					res = t33[31:0];
				end else begin
					t33 = {1'b0, sreg} + {1'b0, dreg} + {32'b0, tmpv[0]};
					sr[3] = (sreg[31] ^ t33[31]) & (dreg[31] ^ t33[31]) & t33[31];
					res = sreg + dreg + {31'b0, tmpv[0]};
				end
				sr[0] = t33[32];
				if (res == 32'd0 && tmpv[1]) sr[1] = 1'b1;
				sr[2] = res[31];
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
			end
			//------------------------------------------------ neg
			8'h58, 8'h59, 8'h5a, 8'h5b: begin
				t64 = 64'd0 - {32'b0, sregc};
				sr[3:0] = 4'b0000;
				sr[0] = t64[32];
				sr[3] = t64[31] & sregc[31];
				res = 32'd0 - sregc;
				sr[2:1] = {res[31], res == 32'd0};
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
			end
			//------------------------------------------------ negs
			8'h5c, 8'h5d, 8'h5e, 8'h5f: begin
				t64 = 64'd0 - {{32{sregc[31]}}, sregc};
				sr[3:1] = 3'b000;
				sr[3] = t64[31] & sregc[31];
				res = 32'd0 - sregc;
				sr[2:1] = {res[31], res == 32'd0};
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
				if (sr[3]) req_exc(TRAP_RANGE);
			end
			//------------------------------------------------ immediate ALU group 0x60-0x7f
			8'h6?, 8'h7?: begin
				// immediate value: LIMM variants (odd opcodes) read it from the stream
				if (opc[0]) begin
					case (sc)
						4'd0: imm = 32'd16;
						4'd1: imm = {e1, e2};
						4'd2: imm = {16'b0, e1};
						4'd3: imm = {16'hffff, e1};
						4'd4: imm = 32'd32;
						4'd5: imm = 32'd64;
						4'd6: imm = 32'd128;
						4'd7: imm = 32'h80000000;
						4'd8: imm = 32'hfffffff8;
						4'd9: imm = 32'hfffffff9;
						4'd10: imm = 32'hfffffffa;
						4'd11: imm = 32'hfffffffb;
						4'd12: imm = 32'hfffffffc;
						4'd13: imm = 32'hfffffffd;
						4'd14: imm = 32'hfffffffe;
						default: imm = 32'hffffffff;
					endcase
				end else imm = {28'b0, sc};
				dreg = dl ? lD_r : gD_r;
				case (opc[3:2])
				2'b00: begin // cmpi (0x60-63), cmpbi is 0x70-73 below
					if (!opc[4]) begin
						t33 = {1'b0, dreg} - {1'b0, imm};
						sr[3:0] = 4'b0000;
						sr[3] = (t33[31] ^ dreg[31]) & (dreg[31] ^ imm[31]);
						if (dreg < imm) sr[0] = 1'b1;
						else if (dreg == imm) sr[1] = 1'b1;
						if ($signed(dreg) < $signed(imm)) sr[2] = 1'b1;
					end else begin
						// cmpbi
						nimm = {opc[0], sc};
						if (nimm != 6'd0) begin
							if (nimm == 6'd31) imm = 32'h7fffffff;
							sr[1] = ((dreg & imm) == 32'd0);
						end else begin
							sr[1] = (dreg[31:24] == 8'd0) || (dreg[23:16] == 8'd0) || (dreg[15:8] == 8'd0) || (dreg[7:0] == 8'd0);
						end
					end
				end
				2'b01: begin
					if (!opc[4]) begin // movi
						tmpv = sr;
						sr[5] = 1'b0;
						if (!dl && tmpv[5] && !sr[18]) req_exc(TRAP_RANGE);
						else begin
							sr[3:1] = 3'b000;
							sr[1] = (imm == 32'd0); sr[2] = imm[31];
							if (!dl) begin
								tmp32b = {1'b0, dc} + (tmpv[5] ? 5'd16 : 5'd0);
								write_dst(1'b1, {1'b0, tmp32b[4:0]}, imm);
								if (tmp32b[4:0] == 5'd0) sr[4] = 1'b0;
							end else wq_push(1'b0, 1'b0, didx, imm);
						end
					end else begin // andni
						if (opc[0] && sc == 4'd15) imm = 32'h7fffffff;
						res = dreg & ~imm;
						sr[1] = (res == 32'd0);
						write_dst(!dl, dl ? didx : {2'b0, dc}, res);
					end
				end
				2'b10: begin
					if (!opc[4]) begin // addi
						if (!opc[0] && sc == 4'd0) imm = {31'b0, sr[0] & (!sr[1] | dreg[0])};
						t33 = {1'b0, imm} + {1'b0, dreg};
						sr[3:0] = 4'b0000;
						sr[0] = t33[32];
						sr[3] = (imm[31] ^ t33[31]) & (dreg[31] ^ t33[31]);
						res = t33[31:0];
						sr[2:1] = {res[31], res == 32'd0};
						write_dst(!dl, dl ? didx : {2'b0, dc}, res);
						if (!dl && dc == 4'd0) sr[4] = 1'b0;
					end else begin // ori
						res = dreg | imm;
						sr[1] = (res == 32'd0);
						write_dst(!dl, dl ? didx : {2'b0, dc}, res);
					end
				end
				default: begin // 2'b11
					if (!opc[4]) begin // addsi
						if (!opc[0] && sc == 4'd0) imm = {31'b0, sr[0] & (!sr[1] | dreg[0])};
						t33 = {1'b0, imm} + {1'b0, dreg};
						sr[3:1] = 3'b000;
						sr[3] = (imm[31] ^ t33[31]) & (dreg[31] ^ t33[31]);
						res = t33[31:0];
						sr[2:1] = {res[31], res == 32'd0};
						write_dst(!dl, dl ? didx : {2'b0, dc}, res);
						if (sr[3]) req_exc(TRAP_RANGE);
					end else begin // xori
						res = dreg ^ imm;
						sr[1] = (res == 32'd0);
						write_dst(!dl, dl ? didx : {2'b0, dc}, res);
					end
				end
				endcase
			end
			//------------------------------------------------ shifts and rotates, local operands
			8'h80, 8'h81, 8'h84, 8'h85: begin // shrdi, sardi
				n5 = opc[0] ? {1'b1, sc} : {1'b0, sc};
				dw = {lD_r, lD1_r};
				sr[2:0] = 3'b000;
				if (opc[0] || sc != 4'd0) begin
					sr[0] = dw[n5 - 5'd1];
					dw = shr64(dw, n5, opc[2]);
				end
				sr[2:1] = {dw[63], dw == 64'd0};
				wq_push(1'b0, 1'b0, didx, dw[63:32]); wq_push(1'b0, 1'b0, didx1, dw[31:0]);
			end
			8'h82, 8'h86: begin // shrd, sard
				if (sidx == didx || sidx == didx1) begin
				end else begin
					n5 = lS_r[4:0];
					dw = {lD_r, lD1_r};
					sr[2:0] = 3'b000;
					if (n5 != 5'd0) begin
						sr[0] = dw[n5 - 5'd1];
						dw = shr64(dw, n5, opc[2]);
					end
					sr[2:1] = {dw[63], dw == 64'd0};
					wq_push(1'b0, 1'b0, didx, dw[63:32]); wq_push(1'b0, 1'b0, didx1, dw[31:0]);
				end
			end
			8'h83, 8'h87: begin // shr, sar
				n5 = lS_r[4:0];
				res = lD_r;
				sr[2:0] = 3'b000;
				if (n5 != 5'd0) begin
					sr[0] = res[n5 - 5'd1];
					res = shr32(res, n5, opc[2]);
				end
				sr[2:1] = {res[31], res == 32'd0};
				wq_push(1'b0, 1'b0, didx, res);
			end
			8'h88, 8'h89, 8'h8a: begin // shldi, shld
				if (opc == 8'h8a && (sidx == didx || sidx == didx1)) begin
				end else begin
					n5 = (opc == 8'h8a) ? lS_r[4:0] : (opc[0] ? {1'b1, sc} : {1'b0, sc});
					hi = lD_r; lo = lD1_r;
					dw = {hi, lo};
					sr[3:0] = 4'b0000;
					if (n5 != 5'd0) sr[0] = dw[6'd64 - {1'b0, n5}];
					tmpv = hi << n5;
					msk = n5 == 5'd0 ? 32'd0 : (32'hffffffff << (6'd32 - {1'b0, n5}));
					if (((hi & msk) != 32'd0 && !tmpv[31]) || (((hi & msk) ^ msk) != 32'd0 && tmpv[31])) sr[3] = 1'b1;
					dw = dw << n5;
					sr[2:1] = {dw[63], dw == 64'd0};
					wq_push(1'b0, 1'b0, didx, dw[63:32]); wq_push(1'b0, 1'b0, didx1, dw[31:0]);
				end
			end
			8'h8b: begin // shl
				n5 = lS_r[4:0];
				hi = lD_r;
				msk = n5 == 5'd0 ? 32'd0 : (32'hffffffff << (6'd32 - {1'b0, n5}));
				sr[3:0] = 4'b0000;
				if (n5 != 5'd0 && hi[6'd32 - {1'b0, n5}]) sr[0] = 1'b1;
				res = hi << n5;
				if (!res[31] ? ((hi & msk) != 32'd0) : (((hi & msk) ^ msk) != 32'd0)) sr[3] = 1'b1;
				sr[2:1] = {res[31], res == 32'd0};
				wq_push(1'b0, 1'b0, didx, res);
			end
			8'h8e: begin // testlz
				wq_push(1'b0, 1'b0, didx, clz32(lS_r));
			end
			8'h8f: begin // rol
				n5 = lS_r[4:0];
				msk = n5 == 5'd0 ? 32'd0 : (32'hffffffff >> (6'd32 - {1'b0, n5}));
				hi = lD_r;
				res = (hi << n5) | (n5 == 5'd0 ? 32'd0 : (hi >> (6'd32 - {1'b0, n5})));
				sr[3:0] = 4'b0000;
				if (!res[31] ? ((res & msk) != 32'd0) : (((res & msk) ^ msk) != 32'd0)) sr[3] = 1'b1;
				sr[1] = (res == 32'd0); sr[2] = res[31];
				if (n5 != 5'd0 && res[0]) sr[0] = 1'b1;
				wq_push(1'b0, 1'b0, didx, res);
			end
			8'h8c, 8'h8d, 8'hac, 8'had, 8'hae, 8'haf: begin
				// reserved: no effect
			end
			//------------------------------------------------ shri, sari, shli
			8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5, 8'ha6, 8'ha7, 8'ha8, 8'ha9, 8'haa, 8'hab: begin
				n5 = opc[0] ? {1'b1, sc} : {1'b0, sc};
				hi = dreg;
				if (opc[3]) begin // shli
					msk = n5 == 5'd0 ? 32'd0 : (32'hffffffff << (6'd32 - {1'b0, n5}));
					sr[3:0] = 4'b0000;
					if (n5 != 5'd0 && hi[6'd32 - {1'b0, n5}]) sr[0] = 1'b1;
					res = hi << n5;
					if (!res[31] ? ((hi & msk) != 32'd0) : (((hi & msk) ^ msk) != 32'd0)) sr[3] = 1'b1;
				end else begin
					sr[2:0] = 3'b000;
					if (opc[0] || sc != 4'd0) sr[0] = hi[n5 - 5'd1];
					res = shr32(hi, n5, opc[2]);
				end
				sr[2:1] = {res[31], res == 32'd0};
				write_dst(!dl, dl ? didx : {2'b0, dc}, res);
			end
			//------------------------------------------------ loads and stores
			8'h90, 8'h91, 8'h92, 8'h93, 8'h94, 8'h95, 8'h96, 8'h97,
			8'h98, 8'h99, 8'h9a, 8'h9b, 8'h9c, 8'h9d, 8'h9e, 8'h9f: begin
				extra_s = e1[15] ? ({e1[14] ? 4'hf : 4'h0, e1[11:0], e2})
				                 : ({e1[14] ? 20'hfffff : 20'h0, e1[11:0]});
				subt = e1[13:12];
				p_w0_en <= 1'b0; p_w1_en <= 1'b0; p_b_en <= 1'b0; p_exc <= 1'b0;
				p_n <= 2'd0; p_loop <= 2'd0;
				exec_ldst();
			end
			//------------------------------------------------ mulsu
			8'hb0, 8'hb1, 8'hb2, 8'hb3, 8'hb4, 8'hb5, 8'hb6, 8'hb7: begin
				if ((!sl && sc < 4'd2) || (!dl && dc < 4'd2)) begin
				end else begin
					mk <= 2'd1; msg <= opc[2]; mA <= sreg; mB <= dreg;
					m_dg <= !dl; m_di <= dl ? didx : {2'b0, dc}; m_di1 <= dl ? didx1 : ({2'b0, dc} + 6'd1);
					nstate = ST_MUL; fin_req = 1'b0;
				end
			end
			//------------------------------------------------ set
			8'hb8, 8'hb9, 8'hba, 8'hbb: begin
				if (!dl && dc < 4'd2) begin
				end else begin
					nsr_mask = 32'd0;
					case (sc)
						4'd4, 4'd5: nsr_mask = 32'h6;
						4'd6, 4'd7: nsr_mask = 32'h4;
						4'd8, 4'd9: nsr_mask = 32'h3;
						4'd10, 4'd11: nsr_mask = 32'h1;
						4'd12, 4'd13: nsr_mask = 32'h2;
						4'd14, 4'd15: nsr_mask = 32'h8;
						default: nsr_mask = 32'd0;
					endcase
					cond = (sr & nsr_mask) != 32'd0;
					if (opc[0]) begin // HI
						if (sc >= 4'd4 || sc == 4'd2) begin
							if (sc[0]) res = cond ? 32'd0 : 32'hffffffff;
							else if (sc == 4'd2) res = 32'hffffffff;
							else res = cond ? 32'hffffffff : 32'd0;
							write_raw(!dl, dl ? didx : {2'b0, dc}, res);
						end
					end else begin
						if (sc == 4'd0) begin
							res = (G[18] & 32'hfffffe00) | {23'b0, fp, 2'b00} |
							      {31'b0, (G[18][8] && !sr[31])};
							write_raw(!dl, dl ? didx : {2'b0, dc}, res);
						end else if (sc >= 4'd2) begin
							if (sc[0]) res = {31'b0, !cond};
							else if (sc == 4'd2) res = 32'd1;
							else res = {31'b0, cond};
							if (sc == 4'd3) res = 32'd0;
							write_raw(!dl, dl ? didx : {2'b0, dc}, res);
						end
					end
				end
			end
			//------------------------------------------------ mul
			8'hbc, 8'hbd, 8'hbe, 8'hbf: begin
				if ((!sl && sc < 4'd2) || (!dl && dc < 4'd2)) begin
				end else begin
					mk <= 2'd0; msg <= 1'b1; mA <= sreg; mB <= dreg;
					m_dg <= !dl; m_di <= dl ? didx : {2'b0, dc};
					nstate = ST_MUL; fin_req = 1'b0;
				end
			end
			//------------------------------------------------ floating point: software emulation trap
			8'hc0, 8'hc1, 8'hc2, 8'hc3, 8'hc4, 8'hc5, 8'hc6, 8'hc7, 8'hc8, 8'hc9, 8'hca, 8'hcb, 8'hcc, 8'hcd: begin
				sreg = lS_r; sregf = lS1_r;
				sr[20:19] = 2'd1;
				if (trap_entry == 32'hffffff00) ea = 32'hfffffe00 | {24'b0, opc[3:0], 4'b0};
				else ea = trap_entry | (32'h10c | ({24'b0, (8'hcf - opc)} << 4));
				r8 = {1'b0, fp} + {2'b0, fl_n(sr)};
				wq_push(1'b0, 1'b0, r8[5:0], (G[18] & 32'hffffff00) + 32'h100 + ({26'b0, didx} << 2));
				wq_push(1'b0, 1'b0, r8[5:0] + 6'd1, sreg);
				wq_push(1'b0, 1'b0, r8[5:0] + 6'd2, sregf);
				wq_push(1'b0, 1'b0, r8[5:0] + 6'd3, {pc[31:1], 1'b0} | {31'b0, sr[18]});
				wq_push(1'b0, 1'b0, r8[5:0] + 6'd4, sr);
				sr[24:21] = 4'd6;
				sr[31:25] = r8[6:0];
				sr[4] = 1'b0; sr[16] = 1'b0;
				sr[15] = 1'b1;
				pc = ea;
			end
			//------------------------------------------------ extend
			8'hce: begin
				sreg = lS_r; dreg = lD_r;
				case (e1)
					16'h0100, 16'h0102, 16'h0104, 16'h0106, 16'h010a, 16'h010e, 16'h011a, 16'h011e,
					16'h002a, 16'h002e, 16'h0046, 16'h004e: begin
						// multiplies take two more states (ST_MUL, ST_MUL2)
						mk <= 2'd2; msg <= (e1 != 16'h0104); mA <= sreg; mB <= dreg;
						nstate = ST_MUL; fin_req = 1'b0;
					end
					16'h0086: begin
						tmpv = G[14]; msk = G[15];
						wq_push(1'b1, 1'b1, 6'd14, {sreg[31:16] + tmpv[15:0], sreg[15:0] + msk[15:0]});
						wq_push(1'b1, 1'b1, 6'd15, {sreg[31:16] - tmpv[15:0], sreg[15:0] - msk[15:0]});
					end
					16'h0096: begin
						tmpv = G[14]; msk = G[15];
						wq_push(1'b1, 1'b1, 6'd14, {sreg[31:16] + tmpv[30:15], sreg[15:0] + msk[30:15]});
						wq_push(1'b1, 1'b1, 6'd15, {sreg[31:16] - tmpv[30:15], sreg[15:0] - msk[30:15]});
					end
					16'h0296: begin
						tmpv = G[14]; msk = G[15];
						hi = {16'b0, sreg[31:16]} + {15'b0, tmpv[31:15]};
						lo = {16'b0, sreg[15:0]} + {15'b0, msk[31:15]};
						wq_push(1'b1, 1'b1, 6'd14, {hi[16:1], lo[16:1]});
						hi = {16'b0, sreg[31:16]} - {15'b0, tmpv[31:15]};
						lo = {16'b0, sreg[15:0]} - {15'b0, msk[31:15]};
						wq_push(1'b1, 1'b1, 6'd15, {hi[16:1], lo[16:1]});
					end
					default: ;
				endcase
			end
			//------------------------------------------------ register-indirect loads and stores
			8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5, 8'hd6, 8'hd7,
			8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd, 8'hde, 8'hdf: begin
				p_w0_en <= 1'b0; p_w1_en <= 1'b0; p_b_en <= 1'b0; p_exc <= 1'b0;
				p_n <= 2'd0; p_loop <= 2'd0;
				exec_regind();
			end
			//------------------------------------------------ db / dbr
			8'he0, 8'he1, 8'he2, 8'he3, 8'he4, 8'he5, 8'he6, 8'he7, 8'he8, 8'he9, 8'hea, 8'heb, 8'hec: begin
				case (opc[3:1])
					3'd0: cond = sr[3];
					3'd1: cond = sr[1];
					3'd2: cond = sr[0];
					3'd3: cond = sr[0] | sr[1];
					3'd4: cond = sr[2];
					default: cond = sr[2] | sr[1];
				endcase
				if (opc[0]) cond = !cond;
				if (opc == 8'hec) cond = 1'b1;
				if (op[7]) ofs = {(e1[0] ? 9'h1ff : 9'h000), op[6:0], e1[15:1], 1'b0};
				else ofs = {(op[0] ? 25'h1ffffff : 25'h0), op[6:1], 1'b0};
				if (!delay_slot) begin
					delay_slot_taken = 1'b0;
					if (cond) begin
						delay_slot = 1'b1;
						delay_pc = pc + ofs;
						intblock = 2'd2;
					end
				end else begin
					delay_slot = 1'b0;
					delay_slot_taken = 1'b1;
					if (cond) begin
						pc = delay_pc + ofs;
						sr[4] = 1'b0;
					end else pc = delay_pc;
				end
			end
			//------------------------------------------------ frame
			8'hed: begin
				r8 = {1'b0, fp} - {4'b0, sc};
				set_fp(r8[6:0]);
				set_fl(dc);
				sr[4] = 1'b0;
				dsel = $signed({2'b0, G[18][8:2]}) + 9'sd54 - $signed({1'b0, r8}) - $signed({5'b0, fl_n(sr)});
				lp_diff = {dsel[6], dsel[6:0]};
				if (lp_diff < 0) begin
					lp_flag <= (G[18] >= G[19]);
					p_loop <= 2'd1;
					nstate = ST_LOOP;
					
					fin_req = 1'b0;
				end
			end
			//------------------------------------------------ call
			8'hee, 8'hef: begin
				if (e1[15]) begin
					extra_s = {e1[13:0], e2} | (e1[14] ? 32'hc0000000 : 32'h0);
					sr[20:19] = 2'd3;
				end else begin
					extra_s = {18'b0, e1[13:0]} | (e1[14] ? 32'hffffc000 : 32'h0);
					sr[20:19] = 2'd2;
				end
				tmp32 = (!sl && sc == 4'd1) ? 32'd0 : sreg;
				// dst_code 0 means 16
				r8 = {1'b0, fp} + (dc == 4'd0 ? 8'd16 : {4'b0, dc});
				wq_push(1'b0, 1'b0, r8[5:0], {pc[31:1], 1'b0} | {31'b0, sr[18]});
				wq_push(1'b0, 1'b0, r8[5:0] + 6'd1, sr);
				set_fp(r8[6:0]);
				set_fl(4'd6);
				sr[4] = 1'b0;
				pc = {extra_s[31:1], 1'b0} + tmp32;
				intblock = 2'd2;
			end
			//------------------------------------------------ branches
			8'hf0, 8'hf1, 8'hf2, 8'hf3, 8'hf4, 8'hf5, 8'hf6, 8'hf7, 8'hf8, 8'hf9, 8'hfa, 8'hfb, 8'hfc: begin
				case (opc[3:1])
					3'd0: cond = sr[3];
					3'd1: cond = sr[1];
					3'd2: cond = sr[0];
					3'd3: cond = sr[0] | sr[1];
					3'd4: cond = sr[2];
					default: cond = sr[2] | sr[1];
				endcase
				// opcodes 0xf0.. test "set" on even opcodes, "clear" on odd
				if (opc[0]) cond = !cond;
				if (opc == 8'hfc) cond = 1'b1;
				if (op[7]) ofs = {(e1[0] ? 9'h1ff : 9'h000), op[6:0], e1[15:1], 1'b0};
				else ofs = {(op[0] ? 25'h1ffffff : 25'h0), op[6:1], 1'b0};
				if (cond) begin
					pc = pc + ofs;
					sr[4] = 1'b0;
				end
			end
			//------------------------------------------------ trap
			8'hfd, 8'hfe, 8'hff: begin
				res = {26'b0, op[7:2]};
				tmpv = {28'b0, op[9:8], op[1:0]};
				case (tmpv[3:0])
					4'd4, 4'd5: nsr_mask = 32'h6;
					4'd6, 4'd7: nsr_mask = 32'h4;
					4'd8, 4'd9: nsr_mask = 32'h3;
					4'd10, 4'd11: nsr_mask = 32'h1;
					4'd12, 4'd13: nsr_mask = 32'h2;
					4'd14: nsr_mask = 32'h8;
					default: nsr_mask = 32'd0;
				endcase
				if (tmpv[3:0] >= 4'd4 && tmpv[3:0] <= 4'd14 && !tmpv[0]) cond = (sr & nsr_mask) != 32'd0;
				else cond = (sr & nsr_mask) == 32'd0;
				if (cond) req_trap(res[5:0]);
			end
			default: ; // 0xcf and anything unlisted
			endcase
			fold_fetch;
		end

		//----------------------------------------------------------
		ST_MEM: begin
			// issue bus job p_k
			bus_req <= 1'b1;
			bus_wr <= p_wr;
			bus_io <= p_io;
			bus_ifetch <= 1'b0;
			bus_addr <= (p_k == 2'd0) ? p_a0 : p_a1;
			bus_be <= p_io ? 4'b1111 : be_of((p_k == 2'd0) ? p_a0 : p_a1, p_kind);
			bus_wdata <= wd_of((p_k == 2'd0) ? p_a0 : p_a1, p_kind, (p_k == 2'd0) ? p_wd0 : p_wd1);
			req_issued = 1'b1;
			nstate = ST_MWAIT;
		end

		ST_MWAIT: begin
			if (bus_req && bus_ack) begin
				bus_req <= 1'b0;
				if (p_wr) begin fc_valid <= 1'b0; pf_valid <= 1'b0; pf_want = 1'b0; end
				if (!p_wr) begin
					if (p_k == 2'd0) p_r0 <= p_io ? bus_rdata : lane_ext(bus_rdata, bus_addr, p_kind);
					else p_r1 <= p_io ? bus_rdata : lane_ext(bus_rdata, bus_addr, p_kind);
				end
				if (p_loop != 2'd0) begin
					if (p_loop == 2'd1) begin
write_raw(1'b1, 6'd18, G[18] + 32'd4);
lp_diff = lp_diff + 8'sd1;
end else begin
write_dst(1'b0, {G[18][7:2]}, bus_rdata);
lp_diff = lp_diff + 8'sd1;
end
					nstate = ST_LOOP;
				end else if (p_k + 2'd1 < p_n) begin
					p_k <= p_k + 2'd1;
					nstate = ST_MEM;
				end else begin
					// last access: write the results back in this cycle
					tmpv = p_io ? bus_rdata : lane_ext(bus_rdata, bus_addr, p_kind);
					if (p_w0_en) write_dst(p_w0_g, p_w0_i, (p_n == 2'd2) ? p_r0 : tmpv);
					if (p_w1_en) write_dst(p_w1_g, p_w1_i, tmpv);
					if (p_b_en) write_raw(p_b_g, p_b_i, p_b_v);
					if (p_exc) req_exc(TRAP_RANGE);
					fin_req = 1'b1;
					nstate = ST_INT;
					fold_fetch;
				end
			end
		end

		ST_LOOP: if (wq_busy0 || pf_infl) begin
			// the stack pointer update from the previous word has to reach G before it is used
			nstate = ST_LOOP;
		end else begin
			if (lp_diff < 0) begin
				if (p_loop == 2'd1) begin
p_wr <= 1'b1; p_io <= 1'b0; p_kind <= 3'd0; p_k <= 2'd0;
p_a0 <= G[18]; p_wd0 <= lA;
end else begin
write_raw(1'b1, 6'd18, G[18] - 32'd4);
p_wr <= 1'b0; p_io <= 1'b0; p_kind <= 3'd0; p_k <= 2'd0;
p_a0 <= G[18] - 32'd4;
end
				p_n <= 2'd1;
				nstate = ST_MEM;
			end else begin
				if (p_loop == 2'd1 && lp_flag) req_exc(TRAP_RANGE);
p_loop <= 2'd0;
fin_req = 1'b1;
nstate = ST_INT;
				
				
			end
		end

		ST_MPOST: begin
			if (p_w0_en) write_dst(p_w0_g, p_w0_i, p_r0);
if (p_w1_en) write_dst(p_w1_g, p_w1_i, p_r1);
if (p_b_en) write_raw(p_b_g, p_b_i, p_b_v);
if (p_exc) req_exc(TRAP_RANGE);
fin_req = 1'b1;
nstate = ST_INT;
			
			
		end

		//----------------------------------------------------------
		ST_DIV: begin
			// restoring division, one dividend bit per clock
			tmp32 = 32'd0;
			dv_r <= dv_r;
			begin : divstep
				reg [32:0] r2;
				r2 = {dv_r[31:0], dv_n[63]};
				dv_n <= {dv_n[62:0], 1'b0};
				if (r2 >= {1'b0, dv_d}) begin
					dv_r <= r2 - {1'b0, dv_d};
					dv_q <= {dv_q[62:0], 1'b1};
				end else begin
					dv_r <= r2;
					dv_q <= {dv_q[62:0], 1'b0};
				end
			end
			dv_cnt <= dv_cnt + 7'd1;
			if (dv_cnt == 7'd63) nstate = ST_DIVEND;
		end

		ST_DIVEND: begin
			res = dv_dneg ? (~dv_q[31:0] + 32'd1) : dv_q[31:0];
			sr[3:1] = 3'b000;
			sr[1] = (res == 32'd0); sr[2] = res[31];
			write_dst(dv_dg, dv_di, dv_r[31:0]);
write_dst(dv_dg, dv_di + 6'd1, res);
fin_req = 1'b1;
nstate = ST_INT;
			
			
		end

		// register the products, then use them
		ST_MUL: begin
			mp <= $signed({msg & mA[31], mA}) * $signed({msg & mB[31], mB});
			p_ll <= $signed(mB[15:0]) * $signed(mA[15:0]);
			p_hh <= $signed(mB[31:16]) * $signed(mA[31:16]);
			p_lh <= $signed(mB[15:0]) * $signed(mA[31:16]);
			p_hl <= $signed(mB[31:16]) * $signed(mA[15:0]);
			nstate = ST_MUL2;
		end

		ST_MUL2: begin
			fin_req = 1'b1;
			nstate = ST_INT;
			case (mk)
				2'd1: begin // mulsu: 64-bit product to a register pair
					sr[2:1] = {mp[63], mp[63:0] == 64'd0};
					write_raw(m_dg, m_di, mp[63:32]);
					write_raw(m_dg, m_di1, mp[31:0]);
				end
				2'd0: begin // mul: low word
					sr[2:1] = {mp[31], mp[31:0] == 32'd0};
					write_raw(m_dg, m_di, mp[31:0]);
				end
				default: begin // extend
					case (e1)
						16'h0100, 16'h0102: wq_push(1'b1, 1'b1, 6'd15, mp[31:0]);
						16'h0104, 16'h0106: begin wq_push(1'b1, 1'b1, 6'd14, mp[63:32]); wq_push(1'b1, 1'b1, 6'd15, mp[31:0]); end
						16'h010a: wq_push(1'b1, 1'b1, 6'd15, G[15] + mp[31:0]);
						16'h010e: begin
							dw = {G[14], G[15]} + mp[63:0];
							wq_push(1'b1, 1'b1, 6'd14, dw[63:32]); wq_push(1'b1, 1'b1, 6'd15, dw[31:0]);
						end
						16'h011a: wq_push(1'b1, 1'b1, 6'd15, G[15] - mp[31:0]);
						16'h011e: begin
							dw = {G[14], G[15]} - mp[63:0];
							wq_push(1'b1, 1'b1, 6'd14, dw[63:32]); wq_push(1'b1, 1'b1, 6'd15, dw[31:0]);
						end
						// half-word DSP forms. MAME's get_lhs is the LOW half, get_rhs the HIGH half.
						16'h002a: wq_push(1'b1, 1'b1, 6'd15, G[15] + p_ll + p_hh);
						16'h002e: begin
							dw = {G[14], G[15]} + {{32{p_ll[31]}}, p_ll} + {{32{p_hh[31]}}, p_hh};
							wq_push(1'b1, 1'b1, 6'd14, dw[63:32]); wq_push(1'b1, 1'b1, 6'd15, dw[31:0]);
						end
						16'h0046: begin
							wq_push(1'b1, 1'b1, 6'd14, p_ll - p_hh); wq_push(1'b1, 1'b1, 6'd15, p_lh + p_hl);
						end
						default: begin // 16'h004e
							wq_push(1'b1, 1'b1, 6'd14, G[14] + p_ll - p_hh); wq_push(1'b1, 1'b1, 6'd15, G[15] + p_lh + p_hl);
						end
					endcase
				end
			endcase
		end

		ST_FRM: if (wq_cnt != 3'd0) begin
			nstate = ST_FRM;
		end else begin
			apply_frame;
			if (frm_kind == 2'd2) begin
				nstate = ST_INT;
				retire_npc <= pc; retire_sr <= sr;
			end else if (ret_pend) begin
				ret_pend = 1'b0;
				ret_loop_start;
			end else begin
				fin_req = frm_fin;
				nstate = ST_INT;
				if (!frm_fin) begin retire_npc <= pc; retire_sr <= sr; end
			end
		end

		default: nstate = ST_RESET;
		endcase

		// ---- end of cycle: global register commit, register-file write pipeline, completion
		commit_glob;
		if (wq_rd >= wq_cnt) begin wq_rd = 3'd0; wq_cnt = 3'd0; end
		l_we_r <= l_we_n; l_wa_r <= l_wa_n; l_wd_r <= l_wd_n;
		if (frm_req) begin
			nstate = ST_FRM;
		end else if (fin_req) begin
			post_instr;
			retire_pc <= ipc;
			retire_npc <= pc; retire_sr <= sr;
			late_cap = gw_new;   // a queued write to a global register lands after this point
			retire_pending = 1'b1;
			if (!fold_done) nstate = frm_req ? ST_FRM : ST_INT;
			else if (frm_req) nstate = ST_FRM;
		end
		// an exception after the next fetch was started: the read, if any, finishes as a prefetch
		if (fold_done && frm_req && req_issued) begin pf_infl = 1'b1; pf_addr = {fpc[31:2], 2'b00}; pf_want = 1'b0; end
		// the instruction completes once its writes have drained and any frame is built
		if (retire_pending && wq_cnt == 3'd0 && nstate != ST_FRM) begin
			retire_pending = 1'b0;
			retire <= 1'b1;
			if (late_cap) begin retire_npc <= pc; retire_sr <= sr; late_cap = 1'b0; end
		end
		// prefetch when nothing else uses the bus this cycle
		if (pf_want && !pf_infl && !req_issued && !bus_req && nstate != ST_FWAIT && nstate != ST_MWAIT && nstate != ST_MEM) begin
			bus_req <= 1'b1; bus_wr <= 1'b0; bus_io <= 1'b0; bus_ifetch <= 1'b1;
			bus_addr <= pf_addr; bus_be <= 4'b1111; bus_wdata <= 32'd0;
			pf_infl = 1'b1; pf_want = 1'b0;
		end
		state <= nstate;

	end
end

//------------------------------------------------------------------
// load/store execute helpers (called from ST_EXEC)
//------------------------------------------------------------------
reg [31:0] ls_dreg, ls_sreg, ls_sregf, ls_base;
reg        ls_ptr_ok;
reg [5:0]  ls_sidx, ls_didx, ls_sidxf;
reg        ls_dg, ls_sg;
reg [31:0] ls_ea;
reg [31:0] ls_upd;
reg        ls_range;

task job_start(input wr, input io, input [2:0] kind, input [1:0] n,
               input [31:0] a0, input [31:0] a1, input [31:0] w0, input [31:0] w1);
	begin
		p_wr <= wr; p_io <= io; p_kind <= kind; p_n <= n; p_k <= 2'd0;
		p_a0 <= a0; p_a1 <= a1; p_wd0 <= w0; p_wd1 <= w1;
		// the first access goes out in this cycle
		bus_req <= 1'b1; bus_wr <= wr; bus_io <= io; bus_ifetch <= 1'b0;
		bus_addr <= a0; bus_be <= io ? 4'b1111 : be_of(a0, kind); bus_wdata <= wd_of(a0, kind, w0);
		req_issued = 1'b1;
		nstate = ST_MWAIT;
		fin_req = 1'b0;
	end
endtask

task exec_ldst;
	reg is_st, is_n;
	reg [1:0] sub;
	reg same;
	begin
		is_st = opc[3];
		is_n  = opc[2];
		sub   = e1[13:12];
		ls_dg = !dl; ls_sg = !sl;
		ls_didx = dl ? didx : {2'b0, dc};
		ls_sidx = sl ? sidx : {2'b0, sc};
		ls_sidxf = sl ? sidx1 : ({2'b0, sc} + 6'd1);
		ls_dreg = dl ? lD_r : ((dc == 4'd1) ? 32'd0 : gD_r);
		if (is_n) ls_dreg = dl ? lD_r : gD_r;
		ls_sreg = (!sl && sc == 4'd1) ? 32'd0 : sreg;
		ls_sregf = sl ? lS1_r : (sc == 4'd1 ? 32'd0 : gS1_r);
		if (!is_st) ls_sregf = 32'd0;

		if (is_n && !dl && dc <= 4'd1) begin
			// MAME: PC/SR as the pointer register does nothing
		end else if (((!is_n) && (dl || dc != 4'd1) && ls_dreg == 32'd0)) begin
			req_exc(TRAP_RANGE);
		end else if (is_n && ls_dreg == 32'd0) begin
			case (sub)
				2'd0, 2'd1: ls_upd = extra_s;
				2'd2: ls_upd = extra_s & 32'hfffffffe;
				default: ls_upd = extra_s & 32'hfffffffc;
			endcase
			write_raw(ls_dg, ls_didx, (ls_dg ? gD_r : lD_r) + ls_upd);
			req_exc(TRAP_RANGE);
		end else begin
			same = (dl != sl) || (ls_sidx != ls_didx);
			p_exc <= 1'b0; p_b_en <= 1'b0; p_w0_en <= 1'b0; p_w1_en <= 1'b0;
			p_b_g <= ls_dg; p_b_i <= ls_didx;
			p_w0_g <= ls_sg; p_w0_i <= ls_sidx;
			p_w1_g <= ls_sg; p_w1_i <= ls_sidxf;
			if (!is_st) begin
				// loads
				p_w0_en <= 1'b1;
				case (sub)
				2'd0: begin // LDBS
					ls_ea = is_n ? ls_dreg : ls_dreg + extra_s;
					job_start(1'b0, 1'b0, 3'd2, 2'd1, ls_ea, 32'd0, 32'd0, 32'd0);
					if (is_n && same) begin write_raw(ls_dg, ls_didx, ls_dreg + extra_s); end
				end
				2'd1: begin // LDBU
					ls_ea = is_n ? ls_dreg : ls_dreg + extra_s;
					job_start(1'b0, 1'b0, 3'd1, 2'd1, ls_ea, 32'd0, 32'd0, 32'd0);
					if (is_n && same) begin write_raw(ls_dg, ls_didx, ls_dreg + extra_s); end
				end
				2'd2: begin // LDHS / LDHU
					ls_ea = is_n ? ls_dreg : ls_dreg + (extra_s & 32'hfffffffe);
					job_start(1'b0, 1'b0, extra_s[0] ? 3'd4 : 3'd3, 2'd1, ls_ea, 32'd0, 32'd0, 32'd0);
					if (is_n && same) begin write_raw(ls_dg, ls_didx, ls_dreg + (extra_s & 32'hfffffffe)); end
				end
				default: begin
					case (extra_s[1:0])
					2'd0: begin // LDW
						ls_ea = is_n ? ls_dreg : ls_dreg + extra_s;
						job_start(1'b0, 1'b0, 3'd0, 2'd1, ls_ea, 32'd0, 32'd0, 32'd0);
						if (is_n && same) begin write_raw(ls_dg, ls_didx, ls_dreg + extra_s); end
					end
					2'd1: begin // LDD
						ls_ea = is_n ? ls_dreg : ls_dreg + (extra_s & 32'hfffffffe);
						job_start(1'b0, 1'b0, 3'd0, 2'd2, ls_ea, ls_ea + 32'd4, 32'd0, 32'd0);
						p_w1_en <= 1'b1;
						// MAME: base update skipped when it is either destination register
						if (is_n && ((dl != sl) || (ls_sidx != ls_didx && ls_sidxf != ls_didx))) begin
							write_raw(ls_dg, ls_didx, ls_dreg + (extra_s & 32'hfffffffe));
						end
					end
					2'd2: begin
						if (is_n) begin
							// reserved
							nstate = ST_INT; p_w0_en <= 1'b0;  
						end else begin // LDW.IOD
							ls_ea = ls_dreg + (extra_s & 32'hfffffffc);
							job_start(1'b0, 1'b1, 3'd0, 2'd1, ls_ea, 32'd0, 32'd0, 32'd0);
						end
					end
					default: begin
						if (is_n) begin // LDW.S: stack space
							if (ls_dreg < G[18]) begin
								job_start(1'b0, 1'b0, 3'd0, 2'd1, ls_dreg, 32'd0, 32'd0, 32'd0);
							end else begin
								p_r0 <= lA;
								nstate = ST_MPOST;  fin_req = 1'b0;
							end
							if (same) begin write_raw(ls_dg, ls_didx, ls_dreg + (extra_s & 32'hfffffffc)); end
						end else begin // LDD.IOD
							ls_ea = ls_dreg + (extra_s & 32'hfffffffc);
							job_start(1'b0, 1'b1, 3'd0, 2'd2, ls_ea, ls_ea + 32'h2000, 32'd0, 32'd0);
							p_w1_en <= 1'b1;
						end
					end
					endcase
				end
				endcase
			end else begin
				// stores
				ls_range = 1'b0;
				case (sub)
				2'd0: begin // STBS
					ls_ea = is_n ? ls_dreg : ls_dreg + extra_s;
					ls_range = !(ls_sreg[31:8] == 24'd0) && !(ls_sreg[31:7] == {25{ls_sreg[7]}});
					job_start(1'b1, 1'b0, 3'd1, 2'd1, ls_ea, 32'd0, ls_sreg, 32'd0);
					if (is_n) begin write_raw(ls_dg, ls_didx, ls_dreg + extra_s); end
					p_exc <= ls_range;
				end
				2'd1: begin // STBU
					ls_ea = is_n ? ls_dreg : ls_dreg + extra_s;
					job_start(1'b1, 1'b0, 3'd1, 2'd1, ls_ea, 32'd0, ls_sreg, 32'd0);
					if (is_n) begin write_raw(ls_dg, ls_didx, ls_dreg + extra_s); end
				end
				2'd2: begin // STHS / STHU
					ls_ea = is_n ? ls_dreg : ls_dreg + (extra_s & 32'hfffffffe);
					ls_range = extra_s[0] && !(ls_sreg[31:16] == 16'd0) && !(ls_sreg[31:15] == {17{ls_sreg[15]}});
					job_start(1'b1, 1'b0, 3'd3, 2'd1, ls_ea, 32'd0, ls_sreg, 32'd0);
					if (is_n) begin write_raw(ls_dg, ls_didx, ls_dreg + (extra_s & 32'hfffffffe)); end
					p_exc <= ls_range;
				end
				default: begin
					case (extra_s[1:0])
					2'd0: begin // STW
						ls_ea = is_n ? ls_dreg : ls_dreg + (extra_s & 32'hfffffffe);
						job_start(1'b1, 1'b0, 3'd0, 2'd1, ls_ea, 32'd0, ls_sreg, 32'd0);
						if (is_n) begin write_raw(ls_dg, ls_didx, ls_dreg + extra_s); end
					end
					2'd1: begin // STD
						ls_ea = is_n ? ls_dreg : ls_dreg + (extra_s & 32'hfffffffe);
						if (is_n && ls_sidxf == ls_didx && (dl == sl) && !(!sl && sc == 4'd1)) ls_sregf = ls_dreg + (extra_s & 32'hfffffffe);
						job_start(1'b1, 1'b0, 3'd0, 2'd2, ls_ea, ls_ea + 32'd4, ls_sreg, ls_sregf);
						if (is_n) begin write_raw(ls_dg, ls_didx, ls_dreg + (extra_s & 32'hfffffffe)); end
					end
					2'd2: begin
						if (is_n) begin
							nstate = ST_INT;  
						end else begin // STW.IOD
							ls_ea = ls_dreg + (extra_s & 32'hfffffffc);
							job_start(1'b1, 1'b1, 3'd0, 2'd1, ls_ea, 32'd0, ls_sreg, 32'd0);
						end
					end
					default: begin
						if (is_n) begin // STW.S
							if (ls_dreg < G[18]) begin
								job_start(1'b1, 1'b0, 3'd0, 2'd1, ls_dreg, 32'd0, ls_sreg, 32'd0);
							end else begin
								wq_push(1'b0, 1'b0, ls_dreg[7:2], ls_sreg);
								nstate = ST_MPOST;  fin_req = 1'b0;
							end
							// MAME: when the pointer's own register-file slot is the target, the update adds to the stored value
							write_raw(ls_dg, ls_didx, ((dl && ls_dreg >= G[18] && ls_dreg[7:2] == didx) ? ls_sreg : ls_dreg) + (extra_s & 32'hfffffffc));
						end else begin // STD.IOD
							ls_ea = ls_dreg + (extra_s & 32'hfffffffc);
							job_start(1'b1, 1'b1, 3'd0, 2'd2, ls_ea, ls_ea + 32'h2000, ls_sreg, ls_sregf);
						end
					end
					endcase
				end
				endcase
			end
		end
	end
endtask

// 0xd0-0xdf: register-indirect load/store, with optional post-increment
task exec_regind;
	reg is_st, is_dbl, is_pi;
	reg [31:0] d;
	begin
		is_st = opc[3]; is_dbl = opc[1]; is_pi = opc[2];
		ls_sg = !sl;
		ls_sidx = sl ? sidx : {2'b0, sc};
		ls_sidxf = sl ? sidx1 : ({2'b0, sc} + 6'd1);
		d = lD_r;
		ls_sreg = (!sl && sc == 4'd1) ? 32'd0 : sreg;
		ls_sregf = sl ? lS1_r : ((sc == 4'd1) ? 32'd0 : gS1_r);
		p_b_g <= 1'b0; p_b_i <= didx;
		p_w0_g <= ls_sg; p_w0_i <= ls_sidx; p_w1_g <= ls_sg; p_w1_i <= ls_sidxf;
		p_exc <= 1'b0; p_w0_en <= 1'b0; p_w1_en <= 1'b0; p_b_en <= 1'b0;
		// MAME: STD.P reads the second source after the pointer update
		if (is_st && is_pi && is_dbl && sl && sidx1 == didx) ls_sregf = d + 32'd8;
		if (is_st && is_pi) wq_push(1'b0, 1'b0, didx, d + (is_dbl ? 32'd8 : 32'd4));   // MAME: updated before the store
		if (!is_st && is_pi && d == 32'd0) wq_push(1'b0, 1'b0, didx, d + (is_dbl ? 32'd8 : 32'd4));
		if (d == 32'd0) req_exc(TRAP_RANGE);
		else begin
			if (!is_st) begin
				p_w0_en <= 1'b1; p_w1_en <= is_dbl;
				if (is_pi) begin
					// MAME: skipped when the pointer is also a destination
					if (sl ? (is_dbl ? (sidx != didx && sidx1 != didx) : (sidx != didx)) : 1'b1) begin
						write_raw(1'b0, didx, d + (is_dbl ? 32'd8 : 32'd4));
					end
				end
				job_start(1'b0, 1'b0, 3'd0, is_dbl ? 2'd2 : 2'd1, d, d + 32'd4, 32'd0, 32'd0);
			end else begin
				job_start(1'b1, 1'b0, 3'd0, is_dbl ? 2'd2 : 2'd1, d, d + 32'd4, ls_sreg, ls_sregf);
			end
		end
	end
endtask

endmodule
