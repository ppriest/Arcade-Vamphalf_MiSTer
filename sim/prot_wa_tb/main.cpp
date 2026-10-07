// World Adventure's protection against MAME: replays the port 0x160 accesses of scripts/mame_prot_trace.py's
// capture (+io=<set>_io.txt) and checks every read against MAME's value.
#include "Vtb_prot_wa.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <string>
double sc_time_stamp() { return 0; }
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::string p;
	for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "+io=", 4)) p = argv[i] + 4;
	FILE *f = fopen(p.c_str(), "r");
	if (!f) { fprintf(stderr, "+io\n"); return 2; }
	Vtb_prot_wa *t = new Vtb_prot_wa;
	auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
	t->rst = 1; t->wr = 0; t->rd = 0; tick(); tick(); t->rst = 0;
	char ln[128]; long frame; char k; unsigned a, d; int reads = 0, bad = 0, writes = 0;
	while (fgets(ln, sizeof ln, f)) {
		if (sscanf(ln, "%ld %c %x %x", &frame, &k, &a, &d) != 4 || a != 0x160) continue;
		if (k == 'W') { t->wr = 1; t->wd = d & 0xffff; tick(); t->wr = 0; writes++; }
		else {
			t->eval();
			if (t->rdata != (d & 0xffff)) { bad++; printf("frame %ld read: RTL %04x, MAME %04x\n", frame, t->rdata, d & 0xffff); }
			t->rd = 1; tick(); t->rd = 0; reads++;
		}
		tick();
	}
	printf("%d writes, %d reads, %d differ\n", writes, reads, bad);
	delete t;
	return bad ? 1 : 0;
}
