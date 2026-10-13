// The whole Limenko core (emu, Limenko.sv) from power-up, as MiSTer drives it with the fast load: the PLL locks,
// the core runs +pre clocks with RESET low and no ROM (the video, and lm_fb's DDR3 reads, run), then RESET is
// held while the .mra's mod byte arrives as ioctl index 1 and the index-0 download carries no bytes (the HPS has
// put the image in DDR3), and the copy runs on the reset release. The copy is checked word for word, with the
// QS1000's u7 and the EEPROM; then the game runs.
//
//   run_verilator.sh lm_top_tb +img=<image.bin> +mod=<byte> [+dsw=<byte>] [+pre=N] [+race=1] [+frames=N]
//                    [+snap=F,...] [+out=<dir>]
//
// +race=1 releases RESET two clocks after lm_fb issues a DDR3 line read, so the copy starts with that read's
// data still to come: the board's case when the reset release follows the download by a line or more.
// +dsw sends the .mra's <switches> byte (ioctl index 254); every QS1000 sample out is then checked against
// "Volume Boost" applied to the chip's output.
//
// +img is scripts/build_mra_lm.py --image <set> <file>; +mod the .mra's <rom index="1"> byte.
#include "Vtb_lm_top.h"
#include "Vtb_lm_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
#include <fcntl.h>

double sc_time_stamp() { return 0; }

static std::string arg(int argc, char **argv, const char *key, const char *def = "") {
	size_t n = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, n)) return std::string(argv[i] + n);
	return def;
}

static const uint32_t LM_SNDCPU = 0x200000, LM_EEPROM = 0x280000;

int main(int argc, char **argv) {
#ifdef _WIN32
	_fmode = _O_BINARY;
#endif
	Verilated::commandArgs(argc, argv);
	std::string imgp = arg(argc, argv, "+img=");
	int mod = (int)strtol(arg(argc, argv, "+mod=", "0").c_str(), nullptr, 0);
	int dsw = (int)strtol(arg(argc, argv, "+dsw=", "-1").c_str(), nullptr, 0);
	uint64_t pre = strtoull(arg(argc, argv, "+pre=", "2000000").c_str(), nullptr, 0);
	bool race = atoi(arg(argc, argv, "+race=", "0").c_str()) != 0;
	int nframes = atoi(arg(argc, argv, "+frames=", "10").c_str());
	std::string outd = arg(argc, argv, "+out=", ".");
	std::set<int> snaps;
	{
		std::string s = arg(argc, argv, "+snap=");
		for (size_t p = 0; p < s.size();) {
			size_t q = s.find(',', p);
			snaps.insert(atoi(s.substr(p, q - p).c_str()));
			if (q == std::string::npos) break;
			p = q + 1;
		}
	}
	FILE *f = fopen(imgp.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot open +img\n"); return 2; }
	fseek(f, 0, SEEK_END); long isz = ftell(f); fseek(f, 0, SEEK_SET);
	std::vector<uint8_t> img(isz);
	if (fread(img.data(), 1, isz, f) != (size_t)isz) return 2;
	fclose(f);

	Vtb_lm_top *top = new Vtb_lm_top;
	auto *r = top->rootp;
	auto &mem = r->tb_lm_top__DOT__u_chip__DOT__mem;
	auto &dm = r->tb_lm_top__DOT__ddr_mem;
	// the image in DDR3, little-endian granules; the rest of DDR3 and all of SDRAM as junk
	uint32_t x = 12345;
	for (size_t i = 0; i < (size_t)1 << 24; i++) {
		x = x * 1103515245u + 12345u;
		uint64_t v = x;
		x = x * 1103515245u + 12345u;
		dm[i] = (v << 32) | x;
	}
	for (size_t g = 0; g * 8 < img.size(); g++) {
		uint64_t v = 0;
		for (int b = 7; b >= 0; b--) v = (v << 8) | (g * 8 + b < img.size() ? img[g * 8 + b] : 0);
		dm[g] = v;
	}
	for (size_t i = 0; i < (size_t)1 << 26; i++) { x = x * 1103515245u + 12345u; mem[i] = (uint16_t)(x >> 16); }

	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	auto &dl = r->tb_lm_top__DOT__u_emu__DOT__hps_io__DOT__dl;
	auto &wr = r->tb_lm_top__DOT__u_emu__DOT__hps_io__DOT__wr;
	auto &idx = r->tb_lm_top__DOT__u_emu__DOT__hps_io__DOT__idx;
	auto &addr = r->tb_lm_top__DOT__u_emu__DOT__hps_io__DOT__addr;
	auto &dout = r->tb_lm_top__DOT__u_emu__DOT__hps_io__DOT__dout;
	auto &ldr_active = r->tb_lm_top__DOT__u_emu__DOT__ldr_active;

	top->reset = 0;
	for (uint64_t i = 0; i < pre; i++) tick();   // the core up, no ROM, RESET low
	top->reset = 1;
	for (int i = 0; i < 2000; i++) tick();
	auto send = [&](int index, size_t a, uint8_t d) {
		idx = index; addr = (uint32_t)a; dout = d; wr = 1;
		tick();
		wr = 0;
		do tick(); while (r->tb_lm_top__DOT__u_emu__DOT__ioctl_wait);
		tick(); tick();
	};
	dl = 1; idx = 1; tick(); tick();
	send(1, 0, (uint8_t)mod);
	tick(); dl = 0; for (int i = 0; i < 100; i++) tick();
	if (dsw >= 0) {
		dl = 1; idx = 254; tick(); tick();
		send(254, 0, (uint8_t)dsw);
		tick(); dl = 0; for (int i = 0; i < 100; i++) tick();
	}
	dl = 1; idx = 0; tick(); tick();
	for (int i = 0; i < 20; i++) tick();
	dl = 0;
	for (int i = 0; i < 200; i++) tick();
	printf("game %d\n", (int)r->tb_lm_top__DOT__u_emu__DOT__game);
	if (race) {
		auto &a_rd = r->tb_lm_top__DOT__u_emu__DOT__u_video__DOT__u_fb__DOT__a_rd;
		uint64_t w = 0;
		while (!a_rd && w < 10000000) { tick(); w++; }
		tick(); tick();
		printf("race: reset released %llu clocks after the download, with an lm_fb read issued\n", (unsigned long long)w + 200);
	}
	top->reset = 0;
	uint64_t c0 = 0, c = 0;
	while (!ldr_active && c0 < 100000) { tick(); c0++; }
	while (ldr_active && c < 300000000) { tick(); c++; }
	if (ldr_active) printf("fast load: still copying after %llu clocks: stopped\n", (unsigned long long)c);
	fflush(stdout);
	size_t bad = 0, n = 0;
	for (size_t i = 0; i + 1 < img.size(); i += 2, n++)
		if (mem[i >> 1] != (uint16_t)(img[i] | (img[i + 1] << 8))) bad++;
	printf("fast load: started %llu clocks after the release, copied in %llu clocks; %zu of %zu SDRAM words differ from the image\n",
		(unsigned long long)c0, (unsigned long long)c, bad, n);
	auto &ee = r->tb_lm_top__DOT__u_emu__DOT__u_main__DOT__u_ee__DOT__mem;
	size_t eebad = 0;
	for (int w = 0; w < 64; w++)
		if (ee[w] != (uint16_t)((img[LM_EEPROM + 2 * w] << 8) | img[LM_EEPROM + 2 * w + 1])) eebad++;
	printf("EEPROM: %zu of 64 words differ from the image's\n", eebad);
	auto &u7 = r->tb_lm_top__DOT__u_emu__DOT__u_snd__DOT__u_mcu__DOT__u_u7__DOT__mem;
	size_t u7bad = 0;
	for (size_t i = 0; i < 0x20000; i++) if (u7[i] != img[LM_SNDCPU + i]) u7bad++;
	printf("QS1000 u7: %zu of 131072 bytes differ from the image\n", u7bad);
	printf("rom_loaded %d core_reset %d\n", (int)r->tb_lm_top__DOT__u_emu__DOT__rom_loaded,
		(int)r->tb_lm_top__DOT__u_emu__DOT__core_reset);
	const int boost = r->tb_lm_top__DOT__u_emu__DOT__vol_boost;
	const bool qs = r->tb_lm_top__DOT__u_emu__DOT__game != 4;
	printf("Volume Boost %d (x%d)\n", boost, 1 << boost);
	auto boosted = [&](int v) { v *= 1 << boost; return v > 32767 ? 32767 : v < -32768 ? -32768 : v; };

	uint64_t retired = 0, ret_f = 0, latches = 0, nonzero = 0, clipped = 0, gain_bad = 0, qs_nz = 0;
	int peak = 0, qs_peak = 0;
	int qs_prev = (int16_t)r->tb_lm_top__DOT__u_emu__DOT__qs_l;
	int frame = 0;
	bool vs_l = false, cap = false;
	std::vector<uint8_t> pix(384 * 240 * 3);
	int npix = 0;
	while (frame < nframes) {
		tick();
		if (r->tb_lm_top__DOT__u_emu__DOT__dbg_retire) retired++;
		if (r->tb_lm_top__DOT__u_emu__DOT__snd_latch_wr) latches++;
		{
			int a = (int16_t)top->audio_l;
			if (qs) {
				if (a != boosted(qs_prev) && gain_bad++ < 5)
					printf("frame %d: AUDIO_L %d, the QS1000's %d boosted is %d\n", frame, a, qs_prev, boosted(qs_prev));
				int q = qs_prev < 0 ? -qs_prev : qs_prev;
				if (q) qs_nz++;
				if (q > qs_peak) qs_peak = q;
				qs_prev = (int16_t)r->tb_lm_top__DOT__u_emu__DOT__qs_l;
			}
			if (a == 32767 || a == -32768) clipped++;
			if (a) nonzero++;
			if (a < 0) a = -a;
			if (a > peak) peak = a;
		}
		if (cap && top->ce_pixel && top->vga_de && npix < 384 * 240) {
			pix[3 * npix] = top->vga_r; pix[3 * npix + 1] = top->vga_g; pix[3 * npix + 2] = top->vga_b;
			npix++;
		}
		bool vs = top->vga_vs;
		if (vs && !vs_l) {
			if (cap) {
				char fn[512];
				snprintf(fn, sizeof fn, "%s/f%d.ppm", outd.c_str(), frame - 1);
				FILE *o = fopen(fn, "wb");
				if (o) { fprintf(o, "P6\n384 240\n255\n"); fwrite(pix.data(), 1, pix.size(), o); fclose(o); }
				cap = false;
			}
			if (frame % 30 == 0) {
				printf("frame %d: %llu instructions, PC %08x, core_reset %d; sound latch writes %llu, audio L peak %d, "
					"non-zero clocks %llu\n", frame, (unsigned long long)(retired - ret_f),
					r->tb_lm_top__DOT__u_emu__DOT__dbg_pc, (int)r->tb_lm_top__DOT__u_emu__DOT__core_reset,
					(unsigned long long)latches, peak, (unsigned long long)nonzero);
				peak = 0; nonzero = 0;
				fflush(stdout);
				ret_f = retired;
			}
			frame++;
			if (snaps.count(frame)) { cap = true; npix = 0; }
		}
		vs_l = vs;
	}
	printf("done: %d frames, %llu instructions\n", frame, (unsigned long long)retired);
	if (qs)
		printf("sound: QS1000 L peak %d, %llu clocks non-zero; AUDIO_L clipped %llu clocks; %llu clocks differ from "
			"the boost\n", qs_peak, (unsigned long long)qs_nz, (unsigned long long)clipped, (unsigned long long)gain_bad);
	// as probe instance D reads them on the board (Limenko_stp)
	printf("first line fill: SDRAM word address %07x, second granule %016llx\n",
		(unsigned)r->tb_lm_top__DOT__u_emu__DOT__u_main__DOT__u_mem__DOT__dbg_fill_a,
		(unsigned long long)r->tb_lm_top__DOT__u_emu__DOT__u_main__DOT__u_mem__DOT__dbg_fill_d);
	delete top;
	return 0;
}
