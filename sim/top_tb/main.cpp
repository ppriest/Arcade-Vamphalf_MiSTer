// The whole core (emu, Vamphalf.sv) from power-up, as MiSTer drives it: the PLL locks, the .mra's mod
// byte arrives as ioctl index 1, the image as index 0 one byte per strobe honouring ioctl_wait, with
// RESET held through the download; then the game runs.
//
//   run_verilator.sh top_tb +img=<image.bin> +mod=<byte> [+frames=N] [+pctrace=<instr.trace>]
//                    [+snap=F,...] [+out=<dir>] [+dlbytes=N]
//
// +dlbytes downloads only the first N bytes of the image (the rest is written into the chip model's
// array first, to save time); the default is the whole image.
#include "Vtb_top.h"
#include "Vtb_top___024root.h"
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

int main(int argc, char **argv) {
#ifdef _WIN32
	_fmode = _O_BINARY;
#endif
	Verilated::commandArgs(argc, argv);
	std::string imgp = arg(argc, argv, "+img=");
	int mod = (int)strtol(arg(argc, argv, "+mod=", "0").c_str(), nullptr, 0);
	int nframes = atoi(arg(argc, argv, "+frames=", "10").c_str());
	std::string pctp = arg(argc, argv, "+pctrace=");
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
	size_t dln = (size_t)strtoul(arg(argc, argv, "+dlbytes=", "0").c_str(), nullptr, 0);
	if (dln == 0 || dln > img.size()) dln = img.size();

	std::vector<uint32_t> mame_pc;
	if (!pctp.empty()) {
		FILE *t = fopen(pctp.c_str(), "r");
		char line[4096];
		while (t && fgets(line, sizeof line, t)) {
			unsigned long long idx; unsigned pc;
			if (line[0] != '#' && sscanf(line, "%llu %x", &idx, &pc) == 2) mame_pc.push_back(pc);
		}
		if (t) fclose(t);
	}

	Vtb_top *top = new Vtb_top;
	auto *r = top->rootp;
	auto &mem = r->tb_top__DOT__u_chip__DOT__mem;
	// the part not downloaded: as left by a previous load (here the image itself); the rest is random
	for (size_t i = dln; i + 1 < img.size(); i += 2) mem[i >> 1] = (uint16_t)(img[i] | (img[i + 1] << 8));

	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	auto &dl = r->tb_top__DOT__u_emu__DOT__hps_io__DOT__dl;
	auto &wr = r->tb_top__DOT__u_emu__DOT__hps_io__DOT__wr;
	auto &idx = r->tb_top__DOT__u_emu__DOT__hps_io__DOT__idx;
	auto &addr = r->tb_top__DOT__u_emu__DOT__hps_io__DOT__addr;
	auto &dout = r->tb_top__DOT__u_emu__DOT__hps_io__DOT__dout;

	top->reset = 1;
	for (int i = 0; i < 2000; i++) tick();         // PLL lock, SDRAM initialisation
	auto send = [&](int index, size_t a, uint8_t d) {
		idx = index; addr = (uint32_t)a; dout = d; wr = 1;
		tick();
		wr = 0;
		do tick(); while (r->tb_top__DOT__u_emu__DOT__ioctl_wait);
		tick(); tick();
	};
	dl = 1; idx = 1; tick(); tick();
	send(1, 0, (uint8_t)mod);
	tick(); dl = 0; for (int i = 0; i < 100; i++) tick();
	dl = 1; idx = 0; tick(); tick();
	for (size_t a = 0; a < dln; a++) {
		send(0, a, img[a]);
		if ((a & 0xfffff) == 0xfffff) { printf("download: %zu MB\n", (a + 1) >> 20); fflush(stdout); }
	}
	for (int i = 0; i < 20; i++) tick();
	dl = 0;
	for (int i = 0; i < 200; i++) tick();
	size_t bad = 0;
	for (size_t i = 0; i + 1 < dln; i += 2)
		if (mem[i >> 1] != (uint16_t)(img[i] | (img[i + 1] << 8))) bad++;
	printf("download: %zu bytes, %zu SDRAM words differ from the image\n", dln, bad);
	top->reset = 0;

	size_t pci = 0;
	bool pc_ok = true;
	uint64_t retired = 0;
	int frame = 0;
	bool vs_l = false, cap = false;
	std::vector<uint8_t> pix(320 * 236 * 3);
	int npix = 0;
	while (frame < nframes) {
		tick();
		if (r->tb_top__DOT__u_emu__DOT__dbg_retire) {
			retired++;
			uint32_t npc = r->tb_top__DOT__u_emu__DOT__dbg_npc;
			if (pc_ok && pci + 1 < mame_pc.size()) {
				if (npc != mame_pc[pci + 1]) {
					printf("pctrace: first difference after instruction %zu: RTL next pc %08x, MAME %08x\n", pci, npc, mame_pc[pci + 1]);
					pc_ok = false;
				}
				pci++;
				if (pc_ok && pci + 1 == mame_pc.size()) printf("pctrace: all %zu instructions agree\n", pci + 1);
			}
		}
		if (cap && top->ce_pixel && top->vga_de && npix < 320 * 236) {
			pix[3 * npix] = top->vga_r; pix[3 * npix + 1] = top->vga_g; pix[3 * npix + 2] = top->vga_b;
			npix++;
		}
		bool vs = top->vga_vs;
		if (vs && !vs_l) {
			if (cap) {
				char fn[512];
				snprintf(fn, sizeof fn, "%s/f%d.ppm", outd.c_str(), frame - 1);
				FILE *o = fopen(fn, "wb");
				if (o) { fprintf(o, "P6\n320 236\n255\n"); fwrite(pix.data(), 1, pix.size(), o); fclose(o); }
				cap = false;
			}
			if (frame % 30 == 0) { printf("frame %d: %llu instructions\n", frame, (unsigned long long)retired); fflush(stdout); }
			frame++;
			if (snaps.count(frame)) { cap = true; npix = 0; }
		}
		vs_l = vs;
	}
	printf("done: %d frames, %llu instructions\n", frame, (unsigned long long)retired);
	delete top;
	return 0;
}
