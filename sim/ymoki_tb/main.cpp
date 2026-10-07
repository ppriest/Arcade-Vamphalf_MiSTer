// YM2151 + M6295 board (rtl/sound/vh_ymoki.sv) driven by MAME's writes.
//
//   run_verilator.sh ymoki_tb +writes=<set>_ymoki.txt +oki=<oki1 region .bin> +wav=<out.wav> [+lat=20]
//
// +writes is scripts/mame_ymoki.py's capture: each write is applied at its machine time in 56 MHz clocks,
// as a one-clock strobe. +oki is MAME's "oki1" region (scripts/build_mra.py --region); the SDRAM port is
// a model that answers each granule request +lat clocks later from it (SD_SAMPLES at 0x200000). The board's
// output is sampled at 48 kHz into +wav for scripts/wav_compare.py against MAME's -wavwrite of the run.
#include "Vtb_ymoki.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <fcntl.h>

double sc_time_stamp() { return 0; }

static std::string arg(int argc, char **argv, const char *key, const char *def = "") {
	size_t n = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, n)) return std::string(argv[i] + n);
	return def;
}

int main(int argc, char **argv) {
#ifdef _WIN32
	_fmode = _O_BINARY;
#endif
	Verilated::commandArgs(argc, argv);
	std::vector<uint8_t> oki;
	{
		FILE *f = fopen(arg(argc, argv, "+oki=").c_str(), "rb");
		if (!f) { fprintf(stderr, "+oki\n"); return 2; }
		uint8_t b[65536]; size_t n;
		while ((n = fread(b, 1, sizeof b, f)) > 0) oki.insert(oki.end(), b, b + n);
		fclose(f);
	}
	struct W { uint64_t t; int kind, a0, d; };
	std::vector<W> ws;
	uint64_t t_end = 0;
	{
		FILE *f = fopen(arg(argc, argv, "+writes=").c_str(), "r");
		if (!f) { fprintf(stderr, "+writes\n"); return 2; }
		char ln[256];
		while (fgets(ln, sizeof ln, f)) {
			unsigned long long t; int a0; unsigned d;
			if (ln[0] == 'Y' && sscanf(ln + 1, "%llu %d %x", &t, &a0, &d) == 3) ws.push_back({t, 0, a0, (int)d});
			else if (ln[0] == 'O' && sscanf(ln + 1, "%llu %x", &t, &d) == 2) ws.push_back({t, 1, 0, (int)d});
			else if (!strncmp(ln, "# end", 5)) { const char *c = strstr(ln, "clock "); if (c) t_end = strtoull(c + 6, nullptr, 10); }
		}
		fclose(f);
	}
	if (ws.empty()) { fprintf(stderr, "no writes\n"); return 2; }
	if (!t_end) t_end = ws.back().t + 56000000ull;
	int lat = atoi(arg(argc, argv, "+lat=", "20").c_str());

	Vtb_ymoki *top = new Vtb_ymoki;
	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	top->rst = 1; top->ym_wr = 0; top->oki_wr = 0; top->sd_ack = 0;
	top->xtal14 = atoi(arg(argc, argv, "+xtal14=", "0").c_str());   // +xtal14=1: the SUPLUP board's clocks
	for (int i = 0; i < 16; i++) tick();
	top->rst = 0;
	tick();
	bool ack = top->sd_ack;                   // the controller's toggle

	std::vector<int16_t> pcm;
	size_t wi = 0;
	int pend = -1;
	uint64_t acc48 = 0;
	for (uint64_t t = 0; t < t_end; t++) {
		top->ym_wr = 0; top->oki_wr = 0;
		if (wi < ws.size() && ws[wi].t <= t) {
			const W &w = ws[wi++];
			if (w.kind == 0) { top->ym_wr = 1; top->ym_a0 = w.a0; top->ym_din = w.d; }
			else { top->oki_wr = 1; top->oki_din = w.d; }
		}
		// SDRAM port model: a toggle request is answered lat clocks later with the granule
		if (pend < 0 && top->sd_req != ack) pend = lat;
		else if (pend == 0) {
			uint32_t byte = ((uint32_t)top->sd_addr << 1) - 0x200000u;
			uint64_t g = 0;
			for (int k = 7; k >= 0; k--) g = (g << 8) | (byte + k < oki.size() ? oki[byte + k] : 0);
			top->sd_dout = g;
			ack = !ack; top->sd_ack = ack;
			pend = -1;
		} else if (pend > 0) pend--;
		tick();
		acc48 += 48000;
		if (acc48 >= 56000000) {
			acc48 -= 56000000;
			pcm.push_back((int16_t)top->out_l); pcm.push_back((int16_t)top->out_r);
		}
	}
	std::string wp = arg(argc, argv, "+wav=");
	FILE *o = fopen(wp.c_str(), "wb");
	if (o) {
		uint32_t rate = 48000, n = (uint32_t)(pcm.size() * 2), v;
		fwrite("RIFF", 1, 4, o); v = 36 + n; fwrite(&v, 4, 1, o); fwrite("WAVEfmt ", 1, 8, o);
		v = 16; fwrite(&v, 4, 1, o);
		uint16_t h[2] = {1, 2}; fwrite(h, 2, 2, o);
		fwrite(&rate, 4, 1, o); v = rate * 4; fwrite(&v, 4, 1, o);
		h[0] = 4; h[1] = 16; fwrite(h, 2, 2, o);
		fwrite("data", 1, 4, o); fwrite(&n, 4, 1, o); fwrite(pcm.data(), 2, pcm.size(), o);
		fclose(o);
	}
	printf("%zu writes applied, %llu clocks, %zu output samples -> %s\n", wi, (unsigned long long)t_end, pcm.size() / 2, wp.c_str());
	delete top;
	return 0;
}
