// QS1000 voice engine against the model, sum for sum.
//
//   run_verilator.sh qs1000v_tb +img=<image.bin> +wave=<set>_wave.txt +mix=<model mix.txt> [+ticks=N]
//                    [+lat=<clocks>] [+jitter=1]
//
// +img is the .mra image (scripts/build_mra.py --image); its sample region (SD_SAMPLES .. SD_GFX) is the
// ROM the engine reads, served one 16-byte line per request after +lat clocks (+jitter adds 0-15).
// +wave is scripts/mame_qs1000_wave.py's capture; +mix is scripts/qs1000_model.py --mix of the same
// capture. Writes stamped with tick T go in before tick T, one per clock; ticks are 75 clocks apart
// (56 MHz / 750 kHz is 74.7). Every tick's left and right sum is compared with the model's line.
#include "Vtb_qs1000v.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <deque>
#include <fcntl.h>

double sc_time_stamp() { return 0; }

static std::string arg(int argc, char **argv, const char *key, const char *def = "") {
	size_t n = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, n)) return std::string(argv[i] + n);
	return def;
}

static const size_t SD_SAMPLES = 0x200000, SD_GFX = 0x800000;

int main(int argc, char **argv) {
#ifdef _WIN32
	_fmode = _O_BINARY;
#endif
	Verilated::commandArgs(argc, argv);
	FILE *f = fopen(arg(argc, argv, "+img=").c_str(), "rb");
	if (!f) { fprintf(stderr, "+img\n"); return 2; }
	std::vector<uint8_t> img(SD_GFX);
	if (fread(img.data(), 1, SD_GFX, f) != SD_GFX) { fprintf(stderr, "short image\n"); return 2; }
	fclose(f);
	const uint8_t *rom = img.data() + SD_SAMPLES;
	size_t romsz = SD_GFX - SD_SAMPLES;

	struct W { uint64_t t; int off, d; };
	std::vector<W> writes;
	{
		FILE *w = fopen(arg(argc, argv, "+wave=").c_str(), "r");
		char ln[256];
		while (w && fgets(ln, sizeof ln, w)) {
			unsigned long long t; unsigned o, d;
			if (sscanf(ln, "W %llu %x %x", &t, &o, &d) == 3) writes.push_back({t, (int)o, (int)d});
		}
		if (w) fclose(w);
	}
	FILE *mf = fopen(arg(argc, argv, "+mix=").c_str(), "r");
	if (writes.empty() || !mf) { fprintf(stderr, "+wave / +mix\n"); return 2; }
	uint64_t nticks = strtoull(arg(argc, argv, "+ticks=", "1000000").c_str(), nullptr, 0);
	int lat = atoi(arg(argc, argv, "+lat=", "20").c_str());
	int jitter = atoi(arg(argc, argv, "+jitter=", "0").c_str());

	Vtb_qs1000v *top = new Vtb_qs1000v;
	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	top->rst = 1; top->wr = 0; top->tick = 0; top->rom_ack = 0;
	top->bal_pcb = arg(argc, argv, "+bal=", "mame") == "pcb";   // +bal=pcb: the PCB balance (model --balance pcb)
	for (int i = 0; i < 8; i++) tick();
	top->rst = 0;

	// ROM model
	int rom_wait = -1;
	uint32_t seed = 1;
	auto service_rom = [&]() {
		top->rom_ack = 0;
		if (top->rom_req) {
			if (rom_wait < 0) { seed = seed * 1103515245u + 12345u; rom_wait = lat + (jitter ? (seed >> 16) % 16 : 0); }
			else if (rom_wait == 0) {
				uint32_t a = top->rom_line << 4;
				for (int w = 0; w < 4; w++) {
					uint32_t v = 0;
					for (int b = 0; b < 4; b++) {
						size_t ad = a + 4 * w + b;
						v = (v << 8) | (ad < romsz ? rom[ad] : 0);
					}
					top->rom_data[3 - w] = v;
				}
				top->rom_ack = 1;
				rom_wait = -1;
			} else rom_wait--;
		}
	};

	uint64_t t0 = writes[0].t;
	size_t wi = 0;
	uint64_t compared = 0, bad = 0, mixes = 0;
	char ln[256];
	auto check = [&]() {
		if (!top->mix_valid) return;
		mixes++;
		long long mt, ml, mr;
		if (!fgets(ln, sizeof ln, mf) || sscanf(ln, "%lld %lld %lld", &mt, &ml, &mr) != 3) return;
		compared++;
		if ((int32_t)top->mix_l != ml || (int32_t)top->mix_r != mr) {
			if (bad < 10) printf("tick %lld: RTL %d %d, model %lld %lld\n", mt, (int32_t)top->mix_l, (int32_t)top->mix_r, ml, mr);
			bad++;
		}
	};
	auto clock = [&]() { service_rom(); tick(); check(); };

	for (uint64_t n = 0; n < nticks; n++) {
		uint64_t t = t0 + n;
		int used = 0;
		while (wi < writes.size() && writes[wi].t <= t) {
			top->wr = 1; top->wr_off = writes[wi].off; top->wr_data = writes[wi].d;
			clock();
			top->wr = 0;
			clock();
			used += 2;
			wi++;
		}
		top->tick = 1;
		clock();
		top->tick = 0;
		for (int k = used + 1; k < 75; k++) clock();
	}
	for (int k = 0; k < 20000; k++) clock();
	printf("%llu ticks, %llu sums compared, %llu differ; queue drops %u, pipeline stalls %u\n",
		(unsigned long long)nticks, (unsigned long long)compared, (unsigned long long)bad,
		top->dbg_drops, top->dbg_stalls);
	delete top;
	return bad ? 1 : 0;
}
