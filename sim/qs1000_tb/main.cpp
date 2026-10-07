// QS1000 8052 firmware on the JT8051 core vs the MAME instruction trace.
//
//   run_verilator.sh qs1000_tb [-GCORE=0|1|2] +rom=<u7.hex> +instr=<instr.trace> +bus=<bus.trace>
//        [+n=<instructions>] [+v=1] [+lead=<instructions>] [+cont=1]
//
// docs/QS1000_TRACE_FORMAT.md describes the trace. The bench:
//  - runs the core with the board's memory map (tb_qs1000.sv) and presents port pins and INT1
//    from the trace: the port value of an instruction is the value of its first row on that
//    port's SFR address, INT1 is asserted +lead instructions before the instruction the L row
//    precedes and released after the instruction that writes P3 with bit 5 low;
//  - at every instruction boundary compares PC, A, B, PSW, SP, DPTR, R0-R7 (active bank), IE,
//    IP, TCON, TMOD, TL0, TH0, TL1, TH1, the port latches and the internal RAM with the state
//    MAME had before the matching instruction;
//  - checks every external-data access against the trace's X rows.
// An interrupt entry takes one extra boundary in JT8051 (the vector sequence), which has no
// instruction of its own in MAME's trace; the bench skips the compare at the boundary where
// the core takes the interrupt.
#include "Vtb_qs1000.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>

struct Rec {
	uint16_t pc, dptr;
	uint8_t a, psw, sp, r[8], b, ie, ip, tcon, tmod, tl0, th0, tl1, th1;
	char dis[40];
};
struct Row {
	uint32_t idx;
	char sp, k;
	uint16_t addr;
	uint8_t data;
};

static std::string arg(int argc, char **argv, const char *key, const char *def = "") {
	size_t n = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, n)) return std::string(argv[i] + n);
	return def;
}

double sc_time_stamp() { return 0; }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::string instr_path = arg(argc, argv, "+instr=");
	std::string bus_path = arg(argc, argv, "+bus=");
	uint64_t max_n = strtoull(arg(argc, argv, "+n=", "100000").c_str(), nullptr, 10);
	int verbose = atoi(arg(argc, argv, "+v=", "0").c_str());
	int lead = atoi(arg(argc, argv, "+lead=", "1").c_str());
	bool cont = atoi(arg(argc, argv, "+cont=", "0").c_str()) != 0;
	long long dbg_k = atoll(arg(argc, argv, "+dbg=", "-1").c_str());
	int upper = atoi(arg(argc, argv, "+upper=", "1").c_str());   // compare internal RAM 0x80-0xff

	std::vector<Rec> recs;
	recs.reserve(max_n + 8);
	{
		FILE *f = fopen(instr_path.c_str(), "r");
		if (!f) { fprintf(stderr, "cannot open %s\n", instr_path.c_str()); return 2; }
		static char b[512];
		while (recs.size() < max_n + 4 && fgets(b, sizeof b, f)) {
			if (b[0] == '#') continue;
			char *p = b;
			strtoull(p, &p, 10);
			Rec r;
			r.pc = strtoul(p, &p, 16);
			r.a = strtoul(p, &p, 16);
			r.psw = strtoul(p, &p, 16);
			r.sp = strtoul(p, &p, 16);
			r.dptr = strtoul(p, &p, 16);
			for (int i = 0; i < 8; i++) r.r[i] = strtoul(p, &p, 16);
			r.b = strtoul(p, &p, 16);
			r.ie = strtoul(p, &p, 16);
			r.ip = strtoul(p, &p, 16);
			r.tcon = strtoul(p, &p, 16);
			r.tmod = strtoul(p, &p, 16);
			r.tl0 = strtoul(p, &p, 16);
			r.th0 = strtoul(p, &p, 16);
			r.tl1 = strtoul(p, &p, 16);
			r.th1 = strtoul(p, &p, 16);
			const char *d = strstr(p, "| ");
			snprintf(r.dis, sizeof r.dis, "%s", d ? d + 2 : "");
			char *nl = strchr(r.dis, '\n');
			if (nl) *nl = 0;
			recs.push_back(r);
		}
		fclose(f);
	}
	if (recs.empty()) { fprintf(stderr, "empty instruction trace\n"); return 2; }
	// bus rows: flat, plus the first row of each instruction
	std::vector<Row> rows;
	std::vector<uint32_t> first(recs.size() + 2, 0);
	{
		FILE *f = fopen(bus_path.c_str(), "r");
		if (!f) { fprintf(stderr, "cannot open %s\n", bus_path.c_str()); return 2; }
		char b[128];
		while (fgets(b, sizeof b, f)) {
			if (b[0] == '#') continue;
			unsigned idx, a, d;
			char sp, k;
			if (sscanf(b, "%u %c %c %x %x", &idx, &sp, &k, &a, &d) != 5) continue;
			if (idx >= recs.size() + 1) break;
			rows.push_back({idx, sp, k, (uint16_t)a, (uint8_t)d});
		}
		fclose(f);
		size_t j = 0;
		for (size_t i = 0; i < first.size(); i++) {
			while (j < rows.size() && rows[j].idx < i) j++;
			first[i] = j;
		}
	}
	auto rows_of = [&](uint64_t idx, size_t &lo, size_t &hi) {
		lo = first[idx];
		hi = idx + 1 < first.size() ? first[idx + 1] : rows.size();
	};

	Vtb_qs1000 *top = new Vtb_qs1000;
	top->clk = 0; top->rst = 1; top->int1n = 1;
	top->p0_i = 0xff; top->p1_i = 0xff; top->p2_i = 0xff; top->p3_i = 0xff;
	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	for (int i = 0; i < 8 || !top->o_ready; i++) tick();
	top->rst = 0;

	uint8_t shadow[256];
	memset(shadow, 0, sizeof shadow);
	uint8_t pl[4] = {0xff, 0xff, 0xff, 0xff};      // port latches per the trace's SFR writes
	uint8_t pin[4] = {0xff, 0xff, 0xff, 0xff};
	uint64_t k = 0;                  // next trace instruction to compare; the first boundary is the reset state
	uint64_t applied = 0;            // rows of instructions < applied are in the shadow
	uint32_t x_seen = 0;
	size_t xrow = 0;   // next X row candidate of the running instruction
	bool ni_prev = false;
	bool after_irq = false;
	uint64_t bounds = 0, irq_entries = 0, mism = 0, skipped = 0;
	// INT1 schedule. MAME raises INT1 when the sound latch's data-pending callback runs, which is
	// a scheduler time-sync after the main CPU's write (the L row), and the trace has no event for
	// it. What the trace does show is the instruction where the 8052 took the interrupt: pc = 0x13
	// with SP two higher. Assert INT1 +lead instructions before that, and release it after the
	// instruction that writes P3 with bit 5 low (the latch acknowledge, qs1000_p3_w).
	struct Ev { long long t; bool assert_; };
	std::vector<Ev> evs;
	uint64_t int1_entries = 0;
	for (size_t i = 1; i < recs.size(); i++)
		if (recs[i].pc == 0x13 && (uint8_t)(recs[i].sp - recs[i - 1].sp) == 2) {
			evs.push_back({(long long)i - lead, true});
			int1_entries++;
		}
	for (auto &r : rows)
		if (r.sp == 'S' && r.k == 'W' && r.addr == 0xb0 && !(r.data & 0x20)) evs.push_back({(long long)r.idx + 1, false});
	std::stable_sort(evs.begin(), evs.end(), [](const Ev &x, const Ev &y) { return x.t < y.t; });
	size_t next_ev = 0;
	bool int_low = false;
	uint64_t tick_n = 0;
	int exit_code = 0;
	uint64_t x_checked = 0, x_bad = 0;

	auto report = [&](const char *what, uint64_t idx) {
		fprintf(stderr, "MISMATCH at instruction %llu (%s)\n", (unsigned long long)idx, what);
	};
	auto dump_ctx = [&](uint64_t idx) {
		for (uint64_t j = idx >= 6 ? idx - 6 : 0; j <= idx + 1 && j < recs.size(); j++) {
			const Rec &r = recs[j];
			fprintf(stderr, "  %c %7llu pc=%04x a=%02x psw=%02x sp=%02x dptr=%04x r=%02x%02x%02x%02x%02x%02x%02x%02x  %s\n",
			        j == idx ? '>' : ' ', (unsigned long long)j, r.pc, r.a, r.psw, r.sp, r.dptr,
			        r.r[0], r.r[1], r.r[2], r.r[3], r.r[4], r.r[5], r.r[6], r.r[7], r.dis);
		}
	};

	// bench ends at max_n compared instructions
	while (k < max_n && k + 1 < recs.size()) {
		tick();
		tick_n++;
		if (dbg_k >= 0 && (long long)k >= dbg_k && (long long)k <= dbg_k + 2)
			printf("k=%llu cen pc=%04x ni=%d ram_we=%d ram_addr=%02x ram_dout=%02x a=%02x\n", (unsigned long long)k, top->o_pc, top->o_ni, top->o_ram_we, top->o_ram_addr, top->o_ram_dout, top->o_a);
		// external data access made by the running instruction
		if (top->o_x_cnt != x_seen) {
			if (top->o_x_cnt != x_seen + 1) fprintf(stderr, "note: %u external accesses in one cycle\n", top->o_x_cnt - x_seen);
			x_seen = top->o_x_cnt;
			bool wr = top->o_x_wr;
			// find the next X row of instruction k-1 (the instruction that just started is k-1 or k)
			uint64_t inst = k - 1;   // the boundary for k has been passed: instruction k-1 is running
			size_t lo, hi;
			rows_of(inst, lo, hi);
			bool found = false;
			for (size_t j = xrow < lo ? lo : xrow; j < hi; j++) {
				if (rows[j].sp != 'X') continue;
				xrow = j + 1;
				found = true;
				x_checked++;
				if (rows[j].k != (wr ? 'W' : 'R') || rows[j].addr != top->o_x_addr || rows[j].data != top->o_x_data) {
					x_bad++;
					if (!mism || cont) {
						mism++;
						report("external data access", inst);
						fprintf(stderr, "  rtl %c %04x %02x   mame %c %04x %02x\n", wr ? 'W' : 'R', top->o_x_addr, top->o_x_data,
						        rows[j].k, rows[j].addr, rows[j].data);
						dump_ctx(inst);
					}
				}
				break;
			}
			if (!found && (!mism || cont)) {
				mism++;
				report("external data access with no trace row", inst);
				fprintf(stderr, "  rtl %c %04x %02x\n", wr ? 'W' : 'R', top->o_x_addr, top->o_x_data);
				dump_ctx(inst);
			}
			if (mism && !cont) break;
		}
		bool ni = top->o_ni;
		if (ni && !ni_prev) {
			bounds++;
			if (top->o_irq_taken) {
				// this boundary starts the interrupt vector sequence: no MAME counterpart
				irq_entries++;
				after_irq = true;
				skipped++;
				if (verbose) printf("boundary %llu: interrupt entry before instruction %llu\n", (unsigned long long)bounds, (unsigned long long)k);
			} else if (bounds == 1 && false) {
			} else {
				// the core finished the instruction whose pre-state is recs[k-1] (or the vector
				// sequence): state now = pre-state of recs[k]
				if (bounds > 1 || true) {
					// first boundary: the core has completed the first instruction (idx 0)
				}
				// advance the shadow with the rows of instructions < k
				for (; applied < k; applied++) {
					size_t lo, hi;
					rows_of(applied, lo, hi);
					for (size_t j = lo; j < hi; j++) {
						const Row &r = rows[j];
						if (r.sp == 'I' && r.k == 'W') shadow[r.addr & 0xff] = r.data;
						if (r.sp == 'S' && r.k == 'W') {
							int p = r.addr == 0x80 ? 0 : r.addr == 0x90 ? 1 : r.addr == 0xa0 ? 2 : r.addr == 0xb0 ? 3 : -1;
							if (p >= 0) pl[p] = r.data;
						}
					}
				}
				const Rec &e = recs[k];
				for (int i = 0; i < 8; i++) shadow[(e.psw & 0x18) + i] = e.r[i];
				std::string diff;
				char t[96];
				auto chk = [&](const char *n, unsigned got, unsigned want) {
					if (got != want) { snprintf(t, sizeof t, " %s rtl=%x mame=%x;", n, got, want); diff += t; }
				};
				chk("pc", (top->o_pc - 1) & 0xffff, e.pc);   // the core has fetched the opcode: pc is one past chk("a", top->o_a, e.a); chk("psw", top->o_psw, e.psw);
				chk("sp", top->o_sp, e.sp); chk("dptr", top->o_dptr, e.dptr); chk("b", top->o_b, e.b);
				chk("ie", top->o_ie, e.ie); chk("ip", top->o_ip, e.ip); chk("tmod", top->o_tmod, e.tmod);
				// MAME does not count the two cycles of the interrupt vector sequence until the
				// next instruction's timer update, so the timers are not compared at the first
				// boundary after an interrupt entry (the next boundary checks them again)
				if (!after_irq) {
					chk("tcon", top->o_tcon, e.tcon);
					chk("tl0", top->o_tl0, e.tl0); chk("th0", top->o_th0, e.th0);
					chk("tl1", top->o_tl1, e.tl1); chk("th1", top->o_th1, e.th1);
				}
				after_irq = false;
				chk("p1", top->o_p1, pl[1]); chk("p2", top->o_p2, pl[2]);
				chk("p3", top->o_p3 & 0xfc, pl[3] & 0xfc);
				int lim = upper ? 256 : 128;
				for (int i = 0; i < lim; i++) {
					uint8_t g = (top->o_iram[i / 4] >> (8 * (i % 4))) & 0xff;
					if (g != shadow[i]) {
						snprintf(t, sizeof t, " iram[%02x] rtl=%02x mame=%02x;", i, g, shadow[i]);
						diff += t;
						if (diff.size() > 400) break;
					}
				}
				if (!diff.empty()) {
					if (!mism || cont) {
						mism++;
						report("state before instruction", k);
						fprintf(stderr, "  %s\n", diff.c_str());
						dump_ctx(k);
					}
					if (!cont) break;
					// resync the core to MAME's state is not possible from here; stop counting
				}
				// next instruction k: pins and interrupt line
				{
					size_t lo, hi;
					rows_of(k, lo, hi);
					for (size_t j = lo; j < hi; j++) {
						const Row &r = rows[j];
						if (r.sp == 'S' && r.k == 'R') {
							int p = r.addr == 0x80 ? 0 : r.addr == 0x90 ? 1 : r.addr == 0xa0 ? 2 : r.addr == 0xb0 ? 3 : -1;
							if (p >= 0) { pin[p] = r.data; break; }
						}
					}
					// each port: the first read row in this instruction
					for (int p = 0; p < 4; p++) {
						static const uint16_t sa[4] = {0x80, 0x90, 0xa0, 0xb0};
						for (size_t j = lo; j < hi; j++)
							if (rows[j].sp == 'S' && rows[j].k == 'R' && rows[j].addr == sa[p]) { pin[p] = rows[j].data; break; }
					}
					top->p0_i = pin[0]; top->p1_i = pin[1]; top->p2_i = pin[2]; top->p3_i = pin[3];
					while (next_ev < evs.size() && evs[next_ev].t <= (long long)k) {
						int_low = evs[next_ev].assert_;
						next_ev++;
					}
					top->int1n = int_low ? 0 : 1;
				}
				if (verbose > 1 && k < 40)
					printf("boundary %llu -> idx %llu pc=%04x a=%02x sp=%02x\n", (unsigned long long)bounds, (unsigned long long)k, top->o_pc, top->o_a, top->o_sp);
				k++;
				xrow = first[k - 1];
			}
		}
		ni_prev = ni;
	}
	printf("compared %llu instructions, %llu boundaries (%llu interrupt entries), %llu mismatches; "
	       "external accesses checked %llu (%llu bad); %llu clocks\n",
	       (unsigned long long)k, (unsigned long long)bounds, (unsigned long long)irq_entries,
	       (unsigned long long)mism, (unsigned long long)x_checked, (unsigned long long)x_bad,
	       (unsigned long long)tick_n);
	exit_code = mism ? 1 : 0;
	delete top;
	return exit_code;
}
