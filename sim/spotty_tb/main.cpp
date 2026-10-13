// Spotty's sound board (rtl/sound/lm_spotty.sv) vs the MAME trace of its AT89C4051
// (scripts/mame_qs1000_trace.py spotty, docs/QS1000_TRACE_FORMAT.md).
//
//   run_verilator.sh spotty_tb +rom=<at89c4051.mcu> +oki=<sou_rom1> +instr=<instr.trace> +bus=<bus.trace>
//        [+n=<instructions>] [+v=1] [+cont=1] [+wav=<file>]
//
// The board runs on its own: P1 and P3 come from the board latch, the M6295 and the sound latch, not from
// the trace. The bench
//  - writes the sound latch before the instruction whose P3 read first shows it pending in MAME (MAME sets
//    pending at a scheduler sync after the main CPU's write, which the trace's L row does not place);
//  - at every instruction boundary compares PC, A, B, PSW, SP, DPTR, R0-R7, IE, IP, TCON, TMOD, the timers,
//    the P1 and P3 SFRs and internal RAM 0x00-0x7f (the AT89C4051 has 128 bytes) with MAME's state;
//  - checks every M6295 write against the one MAME's P3 write makes: the board latch as the trace leaves it
//    (the last P1 write; a write after a status or sound-latch read in between is not predicted, and only
//    counted).
#include "Vtb_spotty.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

struct Rec {
	uint16_t pc, dptr;
	uint8_t a, psw, sp, r[8], b, ie, ip, tcon, tmod, tl0, th0, tl1, th1;
	char dis[40];
};
struct Row {
	uint32_t idx;
	char sp, k;
	uint32_t addr;
	uint8_t data;
};

static std::string arg(int argc, char **argv, const char *key, const char *def = "") {
	size_t n = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, n)) return std::string(argv[i] + n);
	return def;
}

static std::vector<uint8_t> load(const std::string &p) {
	std::vector<uint8_t> v;
	FILE *f = fopen(p.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(2); }
	uint8_t b[65536];
	size_t n;
	while ((n = fread(b, 1, sizeof b, f)) > 0) v.insert(v.end(), b, b + n);
	fclose(f);
	return v;
}

double sc_time_stamp() { return 0; }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::vector<uint8_t> rom = load(arg(argc, argv, "+rom="));
	std::vector<uint8_t> oki = load(arg(argc, argv, "+oki="));
	uint64_t max_n = strtoull(arg(argc, argv, "+n=", "100000").c_str(), nullptr, 10);
	int verbose = atoi(arg(argc, argv, "+v=", "0").c_str());
	bool cont = atoi(arg(argc, argv, "+cont=", "0").c_str()) != 0;
	const int lat = 12;   // SDRAM port model latency, clocks

	std::vector<Rec> recs;
	{
		std::string p = arg(argc, argv, "+instr=");
		FILE *f = fopen(p.c_str(), "r");
		if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); return 2; }
		static char b[512];
		while (recs.size() < max_n + 4 && fgets(b, sizeof b, f)) {
			if (b[0] == '#') continue;
			char *q = b;
			strtoull(q, &q, 10);
			Rec r;
			r.pc = strtoul(q, &q, 16); r.a = strtoul(q, &q, 16); r.psw = strtoul(q, &q, 16);
			r.sp = strtoul(q, &q, 16); r.dptr = strtoul(q, &q, 16);
			for (int i = 0; i < 8; i++) r.r[i] = strtoul(q, &q, 16);
			r.b = strtoul(q, &q, 16); r.ie = strtoul(q, &q, 16); r.ip = strtoul(q, &q, 16);
			r.tcon = strtoul(q, &q, 16); r.tmod = strtoul(q, &q, 16);
			r.tl0 = strtoul(q, &q, 16); r.th0 = strtoul(q, &q, 16);
			r.tl1 = strtoul(q, &q, 16); r.th1 = strtoul(q, &q, 16);
			const char *d = strstr(q, "| ");
			snprintf(r.dis, sizeof r.dis, "%s", d ? d + 2 : "");
			char *nl = strchr(r.dis, '\n');
			if (nl) *nl = 0;
			recs.push_back(r);
		}
		fclose(f);
	}
	std::vector<Row> rows;
	{
		std::string p = arg(argc, argv, "+bus=");
		FILE *f = fopen(p.c_str(), "r");
		if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); return 2; }
		char b[128];
		while (fgets(b, sizeof b, f)) {
			if (b[0] == '#') continue;
			unsigned idx, a, d;
			char sp, k;
			if (sscanf(b, "%u %c %c %x %x", &idx, &sp, &k, &a, &d) != 5) continue;
			if (idx >= recs.size() + 1) break;
			rows.push_back({idx, sp, k, a, (uint8_t)d});
		}
		fclose(f);
	}

	// sound latch writes, placed at the first P3 read that shows them pending; the M6295 writes MAME makes
	struct Lw { uint64_t idx; uint8_t d; };
	struct Ow { uint64_t idx; int d; };   // d < 0: not predicted from the trace
	std::vector<Lw> lws;
	std::vector<Ow> ows;
	{
		int bp1 = 0xff, bp3 = 0xff;
		bool open = false;
		uint8_t od = 0;
		for (size_t j = 0; j < rows.size(); j++) {
			const Row &r = rows[j];
			if (r.sp == 'L') { open = true; od = r.data; continue; }
			if (r.sp != 'S') continue;
			if (r.k == 'R' && r.addr == 0xb0 && open && !(r.data & 4)) { lws.push_back({r.idx, od}); open = false; }
			if (r.k == 'W' && r.addr == 0x90) bp1 = r.data;
			if (r.k == 'W' && r.addr == 0xb0) {
				bool frd = (bp3 & 1) && !(r.data & 1) && !(r.data & 0x80);
				bool fwr = (bp3 & 2) && !(r.data & 2) && !(r.data & 0x80);
				bool flt = (bp3 & 8) && !(r.data & 8);
				if (frd) bp1 = -1;
				if (fwr) ows.push_back({r.idx, bp1});
				if (flt) bp1 = -1;
				bp3 = r.data;
			}
		}
	}
	printf("trace: %zu instructions, %zu latch writes placed, %zu M6295 writes\n", recs.size(), lws.size(), ows.size());

	Vtb_spotty *top = new Vtb_spotty;
	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	top->rst = 1; top->latch_wr = 0; top->sd_ack = 0; top->dl_we = 0;
	for (size_t i = 0; i < 4096; i++) {
		top->dl_we = 1; top->dl_addr = i; top->dl_data = i < rom.size() ? rom[i] : 0xff;
		tick();
	}
	top->dl_we = 0;
	for (int i = 0; i < 16; i++) tick();
	top->rst = 0;
	bool ack = top->sd_ack;

	uint8_t shadow[256];
	memset(shadow, 0, sizeof shadow);
	uint8_t pl1 = 0xff, pl3 = 0xff;
	size_t ri = 0, li = 0, oi = 0;
	uint64_t k = 0, bounds = 0, mism = 0, oki_checked = 0, oki_unpred = 0, oki_bad = 0, tick_n = 0;
	bool ni_prev = false;
	int pend = -1;
	std::vector<int16_t> pcm;
	uint64_t acc48 = 0;
	auto dump_ctx = [&](uint64_t idx) {
		for (uint64_t j = idx >= 6 ? idx - 6 : 0; j <= idx + 1 && j < recs.size(); j++) {
			const Rec &r = recs[j];
			fprintf(stderr, "  %c %7llu pc=%04x a=%02x psw=%02x sp=%02x dptr=%04x  %s\n", j == idx ? '>' : ' ',
			        (unsigned long long)j, r.pc, r.a, r.psw, r.sp, r.dptr, r.dis);
		}
	};

	while (k < max_n && k + 1 < recs.size()) {
		top->latch_wr = 0;
		if (li < lws.size() && lws[li].idx < k) {
			top->latch_wr = 1; top->latch_d = lws[li].d;
			if (verbose) printf("latch %02x before instruction %llu\n", lws[li].d, (unsigned long long)k);
			li++;
		}
		if (pend < 0 && top->sd_req != ack) pend = lat;
		else if (pend == 0) {
			uint32_t byte = ((uint32_t)top->sd_addr << 1) - 0x400000u;
			uint64_t g = 0;
			for (int b = 7; b >= 0; b--) g = (g << 8) | (byte + b < oki.size() ? oki[byte + b] : 0);
			top->sd_dout = g;
			ack = !ack; top->sd_ack = ack;
			pend = -1;
		} else if (pend > 0) pend--;
		tick();
		tick_n++;
		acc48 += 48000;
		if (acc48 >= 56000000) { acc48 -= 56000000; pcm.push_back((int16_t)top->out); }

		if (top->o_oki_wr) {
			uint64_t inst = k ? k - 1 : 0;
			if (oi >= ows.size()) {
				mism++;
				fprintf(stderr, "M6295 write %02x in instruction %llu with none left in the trace\n", top->o_oki_din,
				        (unsigned long long)inst);
				if (!cont) break;
			} else {
				const Ow &w = ows[oi++];
				if (w.d < 0) oki_unpred++;
				else oki_checked++;
				if ((w.idx != inst && w.idx + 1 != inst) || (w.d >= 0 && w.d != top->o_oki_din)) {
					oki_bad++; mism++;
					fprintf(stderr, "M6295 write: rtl %02x in instruction %llu, mame %02x in %llu\n", top->o_oki_din,
					        (unsigned long long)inst, w.d & 0xff, (unsigned long long)w.idx);
					if (!cont) break;
				} else if (verbose) printf("M6295 write %02x in instruction %llu\n", top->o_oki_din, (unsigned long long)inst);
			}
		}

		bool ni = top->o_ni;
		if (ni && !ni_prev) {
			bounds++;
			if (top->o_irq_taken) {
				fprintf(stderr, "interrupt entry before instruction %llu: none expected\n", (unsigned long long)k);
				mism++;
				if (!cont) break;
			}
			// the rows of instructions < k are in the shadow
			for (; ri < rows.size() && rows[ri].idx < k; ri++) {
				const Row &r = rows[ri];
				if (r.sp == 'I' && r.k == 'W') shadow[r.addr & 0xff] = r.data;
				if (r.sp == 'S' && r.k == 'W' && r.addr == 0x90) pl1 = r.data;
				if (r.sp == 'S' && r.k == 'W' && r.addr == 0xb0) pl3 = r.data;
			}
			const Rec &e = recs[k];
			for (int i = 0; i < 8; i++) shadow[(e.psw & 0x18) + i] = e.r[i];
			std::string diff;
			char t[96];
			auto chk = [&](const char *n, unsigned got, unsigned want) {
				if (got != want) { snprintf(t, sizeof t, " %s rtl=%x mame=%x;", n, got, want); diff += t; }
			};
			chk("pc", (top->o_pc - 1) & 0xffff, e.pc);
			chk("a", top->o_a, e.a); chk("psw", top->o_psw, e.psw);
			chk("sp", top->o_sp, e.sp); chk("dptr", top->o_dptr, e.dptr); chk("b", top->o_b, e.b);
			chk("ie", top->o_ie, e.ie); chk("ip", top->o_ip, e.ip); chk("tmod", top->o_tmod, e.tmod);
			chk("tcon", top->o_tcon, e.tcon);
			chk("tl0", top->o_tl0, e.tl0); chk("th0", top->o_th0, e.th0);
			chk("tl1", top->o_tl1, e.tl1); chk("th1", top->o_th1, e.th1);
			chk("p1", top->o_p1, pl1); chk("p3", top->o_p3, pl3);
			for (int i = 0; i < 128; i++) {
				uint8_t g = (top->o_iram[i / 4] >> (8 * (i % 4))) & 0xff;
				if (g != shadow[i]) {
					snprintf(t, sizeof t, " iram[%02x] rtl=%02x mame=%02x;", i, g, shadow[i]);
					diff += t;
					if (diff.size() > 400) break;
				}
			}
			if (!diff.empty()) {
				mism++;
				fprintf(stderr, "MISMATCH at instruction %llu (state before it)\n  %s\n", (unsigned long long)k, diff.c_str());
				dump_ctx(k);
				if (!cont) break;
			}
			k++;
		}
		ni_prev = ni;
	}
	printf("compared %llu instructions, %llu mismatches; latch writes %zu of %zu; M6295 writes %llu checked, "
	       "%llu not predicted, %llu bad, %zu of %zu seen; %llu clocks\n",
	       (unsigned long long)k, (unsigned long long)mism, li, lws.size(), (unsigned long long)oki_checked,
	       (unsigned long long)oki_unpred, (unsigned long long)oki_bad, oi, ows.size(), (unsigned long long)tick_n);
	std::string wp = arg(argc, argv, "+wav=");
	if (!wp.empty()) {
		FILE *o = fopen(wp.c_str(), "wb");
		if (o) {
			uint32_t rate = 48000, n = (uint32_t)(pcm.size() * 2), v;
			fwrite("RIFF", 1, 4, o); v = 36 + n; fwrite(&v, 4, 1, o); fwrite("WAVEfmt ", 1, 8, o);
			v = 16; fwrite(&v, 4, 1, o);
			uint16_t h = 1; fwrite(&h, 2, 1, o); h = 1; fwrite(&h, 2, 1, o);
			fwrite(&rate, 4, 1, o); v = rate * 2; fwrite(&v, 4, 1, o);
			h = 2; fwrite(&h, 2, 1, o); h = 16; fwrite(&h, 2, 1, o);
			fwrite("data", 1, 4, o); fwrite(&n, 4, 1, o);
			fwrite(pcm.data(), 2, pcm.size(), o);
			fclose(o);
		}
	}
	delete top;
	return mism ? 1 : 0;
}
