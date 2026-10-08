// E1 CPU vs MAME instruction trace.
//
//   run_verilator.sh e1_tb +instr=<instr.trace> +bus=<bus.trace> [+n=<instructions>] [+wait=<k>] [+v=1] [+cont=1] [+iomask=0x1ff] [+iodmask=0xffff] [+bus32=1]
//
// +bus32=1: the trace is from a 32-bit program bus (E1-32; docs/E1_TRACE_FORMAT.md, "32-bit bus rows"). A
// dword access is one row, a halfword or byte access is one row whose mask is the lane driven, and the
// I/O defaults become +iomask=0x1fff +iodmask=0xffffffff.
//
// +cont=1: a mismatch is reported and the bench goes on. After a state mismatch it forces the RTL's
// pc, sr, globals and locals to MAME's state and clears the delay-slot and interrupt-block flags
// (sim/e1_tb/e1.vlt makes them writable), so the next instruction is checked from a known state.
// A mismatch within 3 instructions of a forced resync is printed as "cascade" and not counted
// (it can come from the hidden state, e.g. a delay slot, that MAME's trace does not show).
//
// Not reproducible from the trace, so the bench supplies them: MAME's TR (`MOV Ln, TR` loads the RTL's TR with the
// value MAME read) and the timer interrupt (tick is tied off in tb_e1; timer_pend is forced when the trace shows
// the timer vector). Interrupt vectors are recognised for the MEM3 table and for tables relocated by TPR.
//
// MAME's interpreter trace gives the register state before every instruction and the
// bus accesses each made. The bench serves instruction fetches from the words seen
// in the trace, serves data reads by replaying the trace in order, checks that every
// write and read the RTL issues matches the trace, and after each instruction compares
// PC, SR and all registers with the state before the next one.
#include "Vtb_e1.h"
#include "Vtb_e1___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <unordered_map>

struct Rec {
	uint64_t idx = 0;
	uint32_t pc = 0, sr = 0;
	uint16_t ops[3] = {0, 0, 0};
	int nops = 0;
	uint32_t g[32] = {0};
	uint32_t l[64] = {0};
	std::string dis;
};

struct BusRow {
	char kind;      // F R W
	char space;     // P I
	uint32_t addr, data;
	uint32_t mask;
};

static std::string arg(int argc, char **argv, const char *key, const char *def = "") {
	size_t n = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, n)) return std::string(argv[i] + n);
	return def;
}

struct TraceReader {
	FILE *f = nullptr;
	Rec cur;            // full state, delta-applied
	bool have = false;
	char *buf = nullptr;
	size_t cap = 0;
	bool open(const char *p) {
		f = fopen(p, "rb");
		cap = 1 << 16;
		buf = (char *)malloc(cap);
		return f != nullptr;
	}
	// the record after the current one, without moving the reader
	Rec peek() {
		long pos = ftell(f);
		Rec save = cur;
		bool had = have;
		Rec r;
		r.idx = ~0ull;
		if (next()) r = cur;
		cur = save;
		have = had;
		fseek(f, pos, SEEK_SET);
		return r;
	}
	bool next() {
		while (true) {
			if (!fgets(buf, (int)cap, f)) { have = false; return false; }
			if (buf[0] == '#' || buf[0] == '\n') continue;
			break;
		}
		char *p = buf;
		cur.idx = strtoull(p, &p, 10);
		cur.pc = (uint32_t)strtoul(p, &p, 16);
		while (*p == ' ') p++;
		cur.nops = 0;
		while (true) {
			cur.ops[cur.nops++ % 3] = (uint16_t)strtoul(p, &p, 16);
			if (*p == ',') p++; else break;
		}
		cur.sr = (uint32_t)strtoul(p, &p, 16);
		cur.dis.clear();
		while (*p) {
			while (*p == ' ') p++;
			if (*p == '|') {
				p++;
				while (*p == ' ') p++;
				cur.dis = p;
				while (!cur.dis.empty() && (cur.dis.back() == '\n' || cur.dis.back() == '\r')) cur.dis.pop_back();
				break;
			}
			if ((*p == 'g' || *p == 'l') && p[1] >= '0' && p[1] <= '9') {
				char c = *p;
				p++;
				int i = (int)strtol(p, &p, 10);
				if (*p == '=') p++;
				uint32_t v = (uint32_t)strtoul(p, &p, 16);
				if (c == 'g') cur.g[i & 31] = v; else cur.l[i & 63] = v;
			} else if (*p == '\n' || *p == '\r' || !*p) break;
			else p++;
		}
		have = true;
		return true;
	}
};

double sc_time_stamp() { return 0; }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::string instr_path = arg(argc, argv, "+instr=");
	std::string bus_path = arg(argc, argv, "+bus=");
	uint64_t max_n = strtoull(arg(argc, argv, "+n=", "100000").c_str(), nullptr, 10);
	int wait_states = atoi(arg(argc, argv, "+wait=", "0").c_str());
	int verbose = atoi(arg(argc, argv, "+v=", "0").c_str());
	long dbg_at = atol(arg(argc, argv, "+dbg=", "-1").c_str());
	bool cont = atoi(arg(argc, argv, "+cont=", "0").c_str()) != 0;
	// I/O port = address >> 13, limited to the CPU's I/O address bits: 9 for the E1-16 (GMS30C2116,
	// e132xs.cpp gms30c2116_device: 6 + 3), 13 for the E1-32. MAME drops the upper bits.
	bool bus32 = atoi(arg(argc, argv, "+bus32=", "0").c_str()) != 0;
	uint32_t iomask = (uint32_t)strtoul(arg(argc, argv, "+iomask=", bus32 ? "0x1fff" : "0x1ff").c_str(), nullptr, 0);
	// I/O data width: 16 bits on the E1-16 (MAME writes uint16_t(data)); +iodmask=0xffffffff for the E1-32
	uint32_t iodmask = (uint32_t)strtoul(arg(argc, argv, "+iodmask=", bus32 ? "0xffffffff" : "0xffff").c_str(), nullptr, 0);

	// bus trace: group non-fetch rows per instruction index; collect fetch words
	std::unordered_map<uint32_t, uint16_t> fetchmem;
	std::map<uint64_t, std::vector<BusRow>> busrows;
	{
		FILE *f = fopen(bus_path.c_str(), "r");
		if (!f) { fprintf(stderr, "cannot open %s\n", bus_path.c_str()); return 2; }
		char b[256];
		while (fgets(b, sizeof b, f)) {
			if (b[0] == '#') continue;
			unsigned long long idx;
			char k, s;
			unsigned a, d, m = 0xffff;
			int n = sscanf(b, "%llu %c %c %x %x %x", &idx, &k, &s, &a, &d, &m);
			if (n < 5) continue;
			if (idx >= max_n + 4) break;
			if (k == 'F') fetchmem[a] = bus32 ? (uint16_t)((a & 2) ? d : d >> 16) : (uint16_t)d;
			else busrows[idx].push_back({k, s, a, d, m});
		}
		fclose(f);
	}

	TraceReader tr;
	if (!tr.open(instr_path.c_str())) { fprintf(stderr, "cannot open %s\n", instr_path.c_str()); return 2; }
	tr.next();
	Rec exp = tr.cur;               // state before the instruction about to run

	Vtb_e1 *top = new Vtb_e1;
	top->clk = 0; top->reset = 1; top->pause = 0; top->irq_in = 0; top->bus_ack = 0; top->bus_rdata = 0;
	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	for (int i = 0; i < 4; i++) tick();
	top->reset = 0;

	uint64_t instr = 0;           // instructions retired
	size_t row_pos = 0;           // next unconsumed bus row of the running instruction
	int wcnt = 0;
	bool bus_busy = false;
	uint64_t cycles = 0, bus_cycles = 0;
	uint64_t state_cycles[32] = {0};
	uint64_t rd_hist[8] = {0};
	std::map<std::string, uint64_t> rd2_mn;
	int errors = 0;
	std::vector<BusRow> *rows = &busrows[0];
	uint32_t irq_pending = 0;
	int ints_taken = 0;

	int nfail = 0, ncascade = 0;
	bool inst_failed = false;
	long long last_resync = -100;
	// true when the caller should print the details of this failure
	auto fail = [&](const char *why) -> bool {
		if (!cont) {
			fprintf(stderr, "MISMATCH at instruction %llu (%s)\n", (unsigned long long)instr, why);
			errors++;
			return true;
		}
		if (inst_failed) return false;
		inst_failed = true;
		bool casc = (long long)instr - last_resync < 4;
		if (casc) ncascade++; else nfail++;
		fprintf(stderr, "MISMATCH at instruction %llu (%s)%s\n", (unsigned long long)instr, why, casc ? " (cascade)" : "");
		return true;
	};

	long long arm_for = -1;
	int arm_bit = 0;
	bool irq_raised = false, int_retired = false, int_ack_seen = false;
	Rec ip_nx, ip_exp;
	auto compare_state = [&](const Rec &nx, const Rec &exp) {
	uint32_t pc = top->o_npc, sr = top->o_nsr;   // architectural state when the instruction retired
			bool bad = (pc != nx.pc) || (sr != nx.sr);
			uint32_t g[32], l[64];
			for (int i = 0; i < 32; i++) g[i] = top->o_g[i];
			for (int i = 0; i < 64; i++) l[i] = top->o_l[i];
			std::string diff;
			char t[128];
			for (int i = 2; i < 32; i++) {
				if (i == 23 || i == 25) continue;     // TR counts time; ISR is an input
				if (g[i] != nx.g[i]) { snprintf(t, sizeof t, " g%d rtl=%08x mame=%08x;", i, g[i], nx.g[i]); diff += t; bad = true; }
			}
			for (int i = 0; i < 64; i++)
				if (l[i] != nx.l[i]) { snprintf(t, sizeof t, " l%d rtl=%08x mame=%08x;", i, l[i], nx.l[i]); diff += t; bad = true; }
			if (bad && errors == 0) {
				if (fail("state differs after instruction")) {
					fprintf(stderr, "  instruction idx %llu: %08x %04x  %s\n", (unsigned long long)exp.idx, exp.pc, exp.ops[0], exp.dis.c_str());
					fprintf(stderr, "  pc rtl=%08x mame=%08x   sr rtl=%08x mame=%08x\n", pc, nx.pc, sr, nx.sr);
					fprintf(stderr, " %s\n", diff.c_str());
				}
				if (cont) {
					auto *r = top->rootp;
					r->tb_e1__DOT__cpu__DOT__pc = nx.pc;
					r->tb_e1__DOT__cpu__DOT__sr = nx.sr;
					for (int i = 2; i < 32; i++) if (i != 23 && i != 25) r->tb_e1__DOT__cpu__DOT__G[i] = nx.g[i];
					r->tb_e1__DOT__cpu__DOT__l_we_r = 0;
					for (int i = 0; i < 64; i++) {
						r->tb_e1__DOT__cpu__DOT__rf__DOT__m0[i] = nx.l[i];
						r->tb_e1__DOT__cpu__DOT__rf__DOT__m1[i] = nx.l[i];
						r->tb_e1__DOT__cpu__DOT__rf__DOT__m2[i] = nx.l[i];
						r->tb_e1__DOT__cpu__DOT__rf__DOT__m3[i] = nx.l[i];
						r->tb_e1__DOT__cpu__DOT__rf__DOT__m4[i] = nx.l[i];
					}
					r->tb_e1__DOT__cpu__DOT__delay_slot = 0;
					r->tb_e1__DOT__cpu__DOT__delay_slot_taken = 0;
					r->tb_e1__DOT__cpu__DOT__intblock = 0;
					last_resync = (long long)instr;
				}
			}
	};
	uint32_t if_prev = 0;
	int if_wcnt = 0;
	bool if_on = false;
	while (instr < max_n && errors == 0) {
		// instruction port: the 8 bytes at if_addr, wait_states clocks after the address appears (an
		// unchanged request is answered again at once, as vh_cpumem's lookup is)
		top->if_ack = 0;
		if (top->if_req) {
			uint32_t ia = (uint32_t)top->if_addr << 3;
			if (!if_on || ia != if_prev) { if_on = true; if_prev = ia; if_wcnt = wait_states; }
			if (if_wcnt > 0) if_wcnt--;
			else {
				uint64_t d = 0;
				for (uint32_t k = 0; k < 4; k++) {
					uint32_t h = ia + 2 * k;
					d = (d << 16) | (fetchmem.count(h) ? (fetchmem[h] & 0xffff) : ((k & 1) ? 0xbeef : 0xdead));
				}
				top->if_data = d;
				top->if_ack = 1;
			}
		} else if_on = false;
		// bus responder
		top->bus_ack = 0;
		if (top->bus_req) {
			if (!bus_busy) { bus_busy = true; wcnt = wait_states; }
			if (wcnt > 0) wcnt--;
			else {
				uint32_t a = top->bus_addr;
				bool wr = top->bus_wr;
				{
					char space = top->bus_io ? 'I' : 'P';
					uint32_t be = top->bus_be;
					if (row_pos >= rows->size()) {
						if (fail("RTL bus access with no trace row"))
							fprintf(stderr, "  %s addr=%08x be=%x io=%d  pc=%08x  %s\n", wr ? "write" : "read", a, be, top->bus_io, exp.pc, exp.dis.c_str());
						top->bus_rdata = 0;
					} else {
						BusRow &r0 = (*rows)[row_pos];
						uint32_t rdata = 0;
						bool ok = (r0.space == space) && (r0.kind == (wr ? 'W' : 'R'));
						if (bus32 && !top->bus_io) {
							// one row per access; mask = lanes driven, data = those lanes of the 32-bit word
							uint32_t lane = (be & 8 ? 0xff000000u : 0) | (be & 4 ? 0x00ff0000u : 0) |
							                (be & 2 ? 0x0000ff00u : 0) | (be & 1 ? 0x000000ffu : 0);
							uint32_t exp_be = be;
							uint32_t ra = a;
							if (be == 0xf) ra = a & ~3u;
							else if (be == 0xc || be == 0x3) { exp_be = (a & 2) ? 0x3u : 0xcu; ra = a & ~1u; }
							else exp_be = 1u << (3 - (a & 3));
							ok = ok && (be == exp_be) && (r0.addr == ra) && (r0.mask == lane);
							if (!wr) top->bus_rdata = r0.data & lane;
							else ok = ok && ((top->bus_wdata & lane) == (r0.data & lane));
							row_pos += 1;
						} else if (be == 0xf) {
							if (top->bus_io) {
								ok = ok && (r0.addr == ((a >> 13) & iomask));
								rdata = r0.data;
								row_pos += 1;
								if (!wr) top->bus_rdata = rdata;
								else ok = ok && ((top->bus_wdata & iodmask) == (rdata & iodmask));
							} else {
								uint32_t ad = a & ~3u;
								ok = ok && (r0.addr == ad);
								if (row_pos + 1 < rows->size()) {
									BusRow &r1 = (*rows)[row_pos + 1];
									ok = ok && (r1.addr == ad + 2) && r1.kind == r0.kind;
									rdata = ((r0.data & 0xffff) << 16) | (r1.data & 0xffff);
									if (wr) ok = ok && (rdata == top->bus_wdata);
									row_pos += 2;
								} else ok = false;
								if (!wr) top->bus_rdata = rdata;
							}
						} else {
							// Byte and halfword accesses: the byte enables must be the lanes of the address
							// (big-endian: a[1:0]=0 is bits 31:24), and the trace row's lane mask must be
							// the lane MAME drove. Without this a store with the right data in the wrong
							// lane would pass.
							uint32_t ha = a & ~1u;
							bool half = (be == 0xc || be == 0x3);
							uint32_t exp_be = half ? ((a & 2) ? 0x3u : 0xcu) : (1u << (3 - (a & 3)));
							ok = ok && (be == exp_be) && (r0.addr == ha);
							if (!half) ok = ok && (r0.mask == ((a & 1) ? 0x00ffu : 0xff00u));
							else ok = ok && (r0.mask == 0xffff);
							uint32_t v = r0.data;
							if (!wr) {
								if (be == 0xc) rdata = (v & 0xffff) << 16;
								else if (be == 0x3) rdata = v & 0xffff;
								else {
									uint32_t byte = (a & 1) ? (v & 0xff) : ((v >> 8) & 0xff);
									rdata = byte << (8 * (3 - (a & 3)));
								}
								top->bus_rdata = rdata;
							} else {
								uint32_t wd = top->bus_wdata;
								uint32_t got = (a & 2) ? (wd & 0xffff) : (wd >> 16);
								if (half) ok = ok && ((got & 0xffff) == (v & 0xffff));
								else {
									uint32_t byte = (wd >> (8 * (3 - (a & 3)))) & 0xff;
									uint32_t exp = (a & 1) ? (v & 0xff) : ((v >> 8) & 0xff);
									ok = ok && (exp == byte);
								}
							}
							row_pos += 1;
						}
						if (!ok && fail("bus access differs from trace"))
							fprintf(stderr, "  RTL: %s addr=%08x be=%x io=%d wdata=%08x\n  MAME row: %c %c addr=%08x data=%08x mask=%04x\n  pc=%08x  %s\n",
								wr ? "write" : "read", a, be, top->bus_io, top->bus_wdata, r0.kind, r0.space, r0.addr, r0.data, r0.mask, exp.pc, exp.dis.c_str());
					}
				}
				top->bus_ack = 1;
				bus_busy = false;
				bus_cycles++;
			}
		}

		{ int st = top->o_state; if (st >= 0 && st < 32) state_cycles[st]++;
		  if (st == 12) { rd_hist[top->o_wq & 7]++; if (top->o_wq == 2) { std::string m = exp.dis; size_t c = m.find(':'); if (c != std::string::npos) m = m.substr(c + 2); size_t sp = m.find(' '); if (sp != std::string::npos) m = m.substr(0, sp); rd2_mn[m]++; } }
		  if (dbg_at >= 0 && (long)instr >= dbg_at - 1 && (long)instr <= dbg_at + 1) printf("i=%llu state=%d wq=%d pc=%08x sr=%08x irq_in=%x retire=%d\n", (unsigned long long)instr, st, (int)top->o_wq, top->o_pc, top->o_sr, (int)top->irq_in, (int)top->retire); }
		tick();
		cycles++;

		// the RTL took the interrupt: drop the request
		if (arm_for >= 0 && arm_bit == 7 && irq_raised && !top->rootp->tb_e1__DOT__cpu__DOT__timer_pend) int_ack_seen = true;
		if (top->irq_ack) { irq_pending &= ~(uint32_t)top->irq_ack; top->irq_in = irq_pending; if (arm_for >= 0) int_ack_seen = true; }

		if (top->retire) {
			instr++;
			if (row_pos != rows->size() && errors == 0) {
				if (fail("RTL made fewer bus accesses than MAME"))
					fprintf(stderr, "  expected %zu rows, consumed %zu; instruction %s at %08x\n", rows->size(), row_pos, exp.dis.c_str(), exp.pc);
			}
			if (!tr.next()) break;
			Rec nx = tr.cur;
			if (arm_for == (long long)exp.idx) {
				// the interrupt follows this instruction: compare once the RTL has built the frame
				int_retired = true; ip_nx = nx; ip_exp = exp;
			} else {
				compare_state(nx, exp);
			}
			// an interrupt that did not arrive in time is a failure of the previous arming
			if (arm_for >= 0 && irq_raised && !int_retired && (long long)exp.idx > arm_for) {
				fail("RTL did not take the interrupt MAME took");
				arm_for = -1; irq_raised = false; irq_pending = 0; top->irq_in = 0; int_ack_seen = false;
				top->rootp->tb_e1__DOT__cpu__DOT__timer_pend = 0;
			}
			// does MAME take an interrupt after the instruction that runs next (nx)?
			{
				static const struct { uint32_t addr; int bit; } vec[] = {
					{0xffffffd4, 0}, {0xffffffd0, 1}, {0xffffffcc, 2}, {0xffffffc8, 3},
					{0xffffffc4, 4}, {0xffffffc0, 5}, {0xffffffd8, 6}, {0xffffffdc, 7} };
				Rec la = tr.peek();
				// execute_int leaves FL=2 and sets I; a trap instruction to the same address leaves FL=6
				if (arm_for < 0 && la.idx != ~0ull && (la.sr & 0x80) && ((la.sr >> 21) & 0xf) == 2 && la.pc != nx.pc)
					for (auto &v : vec)
						if (la.pc == v.addr) { arm_for = (long long)nx.idx; arm_bit = v.bit; irq_raised = false; }
				// trap table relocated by TPR (MEM0, MEM1, MEM2, IRAM entry): vector = entry | (63 - trapno) * 4
				if (arm_for < 0 && la.idx != ~0ull && (la.sr & 0x80) && ((la.sr >> 21) & 0xf) == 2 && la.pc != nx.pc) {
					static const struct { uint32_t off; int bit; } rel[] = {
						{0x28, 0}, {0x2c, 1}, {0x30, 2}, {0x34, 3}, {0x38, 4}, {0x3c, 5}, {0x24, 6}, {0x20, 7} };
					for (auto &v : rel)
						if ((la.pc & 0x3fffffff) == v.off) { arm_for = (long long)nx.idx; arm_bit = v.bit; irq_raised = false; }
				}
			}
			inst_failed = false;
			if (verbose) printf("%llu %08x %s\n", (unsigned long long)exp.idx, exp.pc, exp.dis.c_str());
			exp = nx;
			// MOV Ln, TR: TR is MAME's cycle-count timer (compute_tr), not reproducible from the trace.
			// Load the RTL's TR with the value MAME read, taken from the destination in the next record.
			{
				int dn;
				size_t c = exp.dis.find(": ");
				if (c != std::string::npos && sscanf(exp.dis.c_str() + c + 2, "MOV L%d, TR", &dn) == 1 && dn >= 0 && dn < 16) {
					Rec la = tr.peek();
					if (la.idx != ~0ull) top->rootp->tb_e1__DOT__cpu__DOT__tr_val = la.l[(((exp.sr >> 25) & 0x7f) + dn) & 63];
				}
			}
			rows = &busrows[exp.idx];
			row_pos = 0;
		}
		// MAME takes an interrupt after instruction arm_for: raise the line while that
		// instruction executes, so the next operand-read state samples it
		if (arm_for >= 0 && !irq_raised && top->o_state == 4) {
			// bit 7 is the timer interrupt: internal to the RTL (tick is tied off in tb_e1), forced through timer_pend
			if (arm_bit == 7) top->rootp->tb_e1__DOT__cpu__DOT__timer_pend = 1;
			else { irq_pending = 1u << arm_bit; top->irq_in = irq_pending; }
			irq_raised = true;
		}
		if (int_retired && int_ack_seen && top->o_wq == 0 && top->o_state != 11) {
			compare_state(ip_nx, ip_exp);
			int_retired = false; int_ack_seen = false; arm_for = -1; irq_raised = false; ints_taken++;
		}
		if (cycles > (max_n + 100) * 400ull) {
			fprintf(stderr, "timeout: %llu cycles, %llu instructions\n", (unsigned long long)cycles, (unsigned long long)instr);
			errors++;
		}
	}
	{
		static const char *nm[] = {"RESET","INT","FETCH","FWAIT","EXEC","MEM","MWAIT","MPOST","LOOP","DIV","DIVEND","FRM","RD","MUL","MUL2"};
		for (int i = 0; i < 15; i++)
			if (state_cycles[i]) printf("  %-6s %6.3f clk/instr\n", nm[i], instr ? (double)state_cycles[i] / instr : 0.0);
	}
	printf("  RD cycles by queue depth at start: 0:%.3f 1:%.3f 2:%.3f 3:%.3f 4+:%.3f\n", (double)rd_hist[0] / instr, (double)rd_hist[1] / instr,
	       (double)rd_hist[2] / instr, (double)rd_hist[3] / instr, (double)(rd_hist[4] + rd_hist[5] + rd_hist[6] + rd_hist[7]) / instr);
	for (auto &kv : rd2_mn)
		if (kv.second * 200 > (uint64_t)instr) printf("    depth2 after %s: %.3f\n", kv.first.c_str(), (double)kv.second / instr);
	printf("interrupts taken: %d\n", ints_taken);
	if (cont) printf("failing instructions: %d (+%d cascade)\n", nfail, ncascade);
	if (cont && nfail) errors++;
	printf("%s: %llu instructions, %llu cycles (%.2f clk/instr), %llu bus cycles\n", errors ? "FAIL" : "PASS",
	       (unsigned long long)instr, (unsigned long long)cycles, instr ? (double)cycles / instr : 0.0, (unsigned long long)bus_cycles);
	delete top;
	return errors ? 1 : 0;
}
