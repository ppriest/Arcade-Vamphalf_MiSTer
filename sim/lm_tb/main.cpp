// Limenko system bench: the main board from reset, on the real SDRAM controller and a chip model.
//
//   run_verilator.sh lm_tb +img=<image.bin> +game=N [+prg1=1] [+frames=N] [+pctrace=<instr.trace>]
//                    [+coin=F] [+start=F] [+hold=K] [+flip=1] [+v=1] [+win=N] [+eedump=<file>] [+nvdump=<file>]
//                    [+snap=F1,F2,...] [+out=<dir>]
//
// +img is the download image (scripts/build_mra_lm.py --image <set> <file>), written into the chip model's
// array before the clock starts; the image's EEPROM (LM_EEPROM) goes in through the 93C46 model's load port.
// +game is the mod byte's game (0 dynabomb, 1 sb2003, 2 legendoh, 3 hrthouse, 4 spotty), +prg1 a 1 MB program
// (spotty). +pctrace compares the CPU's retired PCs with a MAME instruction trace (docs/E1_TRACE_FORMAT.md) and
// reports the first difference: up to the first interrupt the two must agree, after it timing differs.
// +coin / +start press COIN1 / START1 (IN2 bits 18 / 16) at frame F for +hold frames (default 6).
// +win=N prints instructions N-24..N+4 (index, PC, next PC, SR after) and the register-file writes among them
// ("rf <slot> <value>": slots 0-31 G0-G31, 32-63 the local registers' physical slots, as dbg_rf_wa gives them).
// The 8052's data-window reads are checked against the image; the count by bank and the clocks its enable was held
// (banks 2-7 from SDRAM) are printed at the end.
// +eedump writes the 93C46's 64 words at the end, big-endian (MAME's .nv has each word low byte first);
// +nvdump the 4 KB RAM at 0x40000000 in the CPU's byte order, as MAME's hrthouse nvram.
// Per frame with +v=1 (else every 60): instructions retired, cache misses, draw commands, sound latch writes.
#include "Vtb_lm.h"
#include "Vtb_lm___024root.h"
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

static const uint32_t LM_EEPROM = 0x280000, LM_SNDCPU = 0x200000, LM_SAMPLES = 0x400000;

int main(int argc, char **argv) {
#ifdef _WIN32
	_fmode = _O_BINARY;
#endif
	Verilated::commandArgs(argc, argv);
	std::string imgp = arg(argc, argv, "+img=");
	int game = atoi(arg(argc, argv, "+game=", "0").c_str());
	int nframes = atoi(arg(argc, argv, "+frames=", "10").c_str());
	std::string pctp = arg(argc, argv, "+pctrace=");
	int coin_f = atoi(arg(argc, argv, "+coin=", "-1").c_str());
	int start_f = atoi(arg(argc, argv, "+start=", "-1").c_str());
	int hold = atoi(arg(argc, argv, "+hold=", "6").c_str());
	int verbose = atoi(arg(argc, argv, "+v=", "0").c_str());
	std::string outd = arg(argc, argv, "+out=", ".");
	std::set<int> snaps;
	{
		std::string sl = arg(argc, argv, "+snap=");
		for (size_t q = 0; q < sl.size();) {
			size_t c = sl.find(',', q);
			snaps.insert(atoi(sl.substr(q, c - q).c_str()));
			if (c == std::string::npos) break;
			q = c + 1;
		}
	}
	long long win = atoll(arg(argc, argv, "+win=", "-1").c_str());

	FILE *f = fopen(imgp.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot open +img=%s\n", imgp.c_str()); return 2; }
	std::vector<uint8_t> img;
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	img.resize(n);
	if (fread(img.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); return 2; }
	fclose(f);

	std::vector<uint32_t> mame_pc;
	if (!pctp.empty()) {
		FILE *t = fopen(pctp.c_str(), "r");
		if (!t) { fprintf(stderr, "cannot open +pctrace\n"); return 2; }
		char line[4096];
		while (fgets(line, sizeof line, t)) {
			if (line[0] == '#') continue;
			unsigned long long idx; unsigned pc;
			if (sscanf(line, "%llu %x", &idx, &pc) == 2) mame_pc.push_back(pc);
		}
		fclose(t);
		printf("pctrace: %zu instructions\n", mame_pc.size());
	}

	Vtb_lm *top = new Vtb_lm;
	auto &mem = top->rootp->tb_lm__DOT__u_chip__DOT__mem;
	for (size_t i = 0; i + 1 < img.size(); i += 2) mem[i >> 1] = (uint16_t)(img[i] | (img[i + 1] << 8));

	top->clk = 0; top->rst = 1; top->vrst = 1; top->prst = 1; top->pause = 0;
	top->flip = atoi(arg(argc, argv, "+flip=", "0").c_str());   // the OSD's Flip Screen
	top->game = game;
	top->prg1 = atoi(arg(argc, argv, "+prg1=", game == 4 ? "1" : "0").c_str());
	// IN2 bit 29 (bit 13 here): "Sound Enable", default 0 = On; spotty's "Demo Sounds", default 1 = On
	const uint16_t in2_idle = game == 4 ? 0xffff : 0xdfff;
	top->in0 = 0xffff; top->in1 = 0xffff; top->in2 = in2_idle;
	top->ee_blank = 1; top->ee_load_we = 0;
	top->nv_blank = 0; top->snd_dl_we = 0;
	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };

	for (int i = 0; i < 8; i++) tick();           // the PLL locks: the memory side's power-up reset
	top->prst = 0;
	for (int i = 0; i < 64; i++) tick();          // blank the EEPROM array
	top->ee_blank = 0;
	for (int w = 0; w < 64; w++) {
		top->ee_load_we = 1; top->ee_load_addr = w;
		top->ee_load_data = (img[LM_EEPROM + 2 * w] << 8) | img[LM_EEPROM + 2 * w + 1];
		tick();
	}
	top->ee_load_we = 0;
	top->nv_blank = game == 3;                    // hrthouse's NVRAM: all ones, as MAME's default
	for (int i = 0; i < 1100; i++) tick();
	top->nv_blank = 0;
	for (int i = 0; i < 3000; i++) tick();        // the SDRAM's initialisation runs under reset
	for (uint32_t a = 0; a < 0x20000; a++) {     // the QS1000's u7: the first 128 KB of LM_SNDCPU
		top->snd_dl_we = 1; top->snd_dl_addr = a; top->snd_dl_data = img[LM_SNDCPU + a];
		tick();
	}
	top->snd_dl_we = 0;
	top->rst = 0;
	top->vrst = 0;

	uint64_t clocks = 0, retired = 0, ret_frame = 0, x_wait = 0;
	// spotty: the M6295's ROM bytes against the image, its writes, and its output at 48 kHz (+wav=)
	uint64_t sp_rom_n = 0, sp_rom_bad = 0, sp_oki_n = 0, acc48 = 0;
	uint32_t sp_last = ~0u;
	std::vector<int16_t> pcm;
	std::string wavp = arg(argc, argv, "+wav=");
	uint32_t imiss0 = 0, dmiss0 = 0;
	int frame = 0, cmds = 0, latches = 0;
	long x_rd[8] = {0}, x_bad = 0;
	size_t pci = 0;
	bool pc_ok = true;
	std::vector<uint8_t> pix;
	bool cap = false;
	while (frame < nframes) {
		tick();
		clocks++;
		// +snap: the visible 384 x 240 of the frame, as <out>/f<N>.ppm
		if (cap && top->ce_pix && !top->hblank && !top->vblank) {
			pix.push_back(top->vid_r); pix.push_back(top->vid_g); pix.push_back(top->vid_b);
			if (pix.size() == 384 * 240 * 3) {
				char fn[512]; snprintf(fn, sizeof fn, "%s/f%d.ppm", outd.c_str(), frame);
				FILE *o = fopen(fn, "wb"); fprintf(o, "P6\n384 240\n255\n"); fwrite(pix.data(), 1, pix.size(), o); fclose(o);
				cap = false;
			}
		}
		// the 8052's data-window reads, each against the image (bank * 0x10000 + address in LM_SNDCPU)
		if (top->snd_xrd) {
			const uint32_t xa = top->snd_xaddr;
			x_rd[xa >> 16]++;
			if (top->snd_xdata != img[LM_SNDCPU + xa]) {
				if (x_bad < 10) printf("frame %d: 8052 read %05x got %02x, image %02x\n", frame, xa, top->snd_xdata, img[LM_SNDCPU + xa]);
				x_bad++;
			}
		}
		if (top->snd_wait) x_wait++;
		if (game == 4) {
			if (top->sp_rom_ok && top->sp_rom_addr != sp_last) {
				sp_last = top->sp_rom_addr;
				sp_rom_n++;
				if (top->sp_rom_data != img[LM_SAMPLES + sp_last]) {
					if (sp_rom_bad < 10) printf("frame %d: M6295 ROM %05x got %02x, image %02x\n", frame, sp_last, top->sp_rom_data,
						img[LM_SAMPLES + sp_last]);
					sp_rom_bad++;
				}
			}
			if (top->sp_oki_wr) {
				sp_oki_n++;
				if (verbose) printf("frame %d: M6295 write %02x\n", frame, top->sp_oki_din);
			}
			acc48 += 48000;
			if (acc48 >= 56000000) { acc48 -= 56000000; if (!wavp.empty()) pcm.push_back((int16_t)top->sp_out); }
		}
		const bool in_win = win >= 0 && (long long)retired >= win - 24 && (long long)retired <= win + 4;
		if (in_win && top->dbg_rf_we) printf("   rf %2u %08x\n", top->dbg_rf_wa, top->dbg_rf_wd);
		if (top->retire) {
			if (in_win) printf("%llu %08x -> %08x sr %08x\n", (unsigned long long)retired, top->retire_pc, top->retire_npc,
				top->retire_sr);
			retired++;
			// the PC after instruction pci is MAME's PC of instruction pci+1
			if (pc_ok && pci + 1 < mame_pc.size()) {
				if (top->retire_npc != mame_pc[pci + 1]) {
					printf("pctrace: first difference after instruction %zu: RTL next pc %08x, MAME %08x (frame %d)\n",
						pci, top->retire_npc, mame_pc[pci + 1], frame);
					pc_ok = false;
				}
				pci++;
				if (pc_ok && pci + 1 == mame_pc.size())
					printf("pctrace: all %zu instructions agree\n", pci + 1);
			}
		}
		if (top->spr_cmd) cmds++;
		if (top->snd_latch_wr) {
			latches++;
			if (verbose) printf("frame %d: sound latch %02x\n", frame, top->snd_latch);
		}
		if (top->frame_start) {
			if (verbose || frame % 60 == 0)
				printf("frame %5d: %7llu instructions, imiss %u dmiss %u, draw commands %d, PC %08x\n", frame,
					(unsigned long long)(retired - ret_frame), top->st_imiss - imiss0, top->st_dmiss - dmiss0, cmds,
					top->retire_pc);
			ret_frame = retired; imiss0 = top->st_imiss; dmiss0 = top->st_dmiss; cmds = 0;
			frame++;
			if (snaps.count(frame)) { cap = true; pix.clear(); }
			uint16_t in2 = in2_idle;
			if (coin_f >= 0 && frame >= coin_f && frame < coin_f + hold) in2 &= ~(1 << 2);
			if (start_f >= 0 && frame >= start_f && frame < start_f + hold) in2 &= ~(1 << 0);
			top->in2 = in2;
		}
	}
	printf("done: %d frames, %llu clocks, %llu instructions (%.2f clocks each), %d sound latch writes\n",
		frame, (unsigned long long)clocks, (unsigned long long)retired, retired ? (double)clocks / retired : 0.0, latches);
	printf("tile lines overrun: %u; sprite draws unfinished at the interrupt: %u; sprite lines late: %u%c", top->dbg_overrun, top->dbg_spr_late, top->dbg_fb_late, 10);
	printf("8052 data-window reads by bank:");
	for (int b = 0; b < 8; b++) printf(" %ld", x_rd[b]);
	printf("; %ld differ from the image; %llu clocks held for banks 2-7\n", x_bad, (unsigned long long)x_wait);
	if (game == 4)
		printf("spotty: %llu M6295 writes; %llu M6295 ROM addresses read, %llu differ from the image\n",
			(unsigned long long)sp_oki_n, (unsigned long long)sp_rom_n, (unsigned long long)sp_rom_bad);
	if (!wavp.empty()) {
		FILE *o = fopen(wavp.c_str(), "wb");
		uint32_t rate = 48000, n = (uint32_t)(pcm.size() * 2), v;
		uint16_t h;
		fwrite("RIFF", 1, 4, o); v = 36 + n; fwrite(&v, 4, 1, o); fwrite("WAVEfmt ", 1, 8, o);
		v = 16; fwrite(&v, 4, 1, o); h = 1; fwrite(&h, 2, 1, o); fwrite(&h, 2, 1, o);
		fwrite(&rate, 4, 1, o); v = rate * 2; fwrite(&v, 4, 1, o);
		h = 2; fwrite(&h, 2, 1, o); h = 16; fwrite(&h, 2, 1, o);
		fwrite("data", 1, 4, o); fwrite(&n, 4, 1, o); fwrite(pcm.data(), 2, pcm.size(), o);
		fclose(o);
	}
	// +ramdump=<file>: the 2 MB of work RAM (LM_WRAM) in the CPU's byte order; an SDRAM word holds the even byte
	// in bits 7:0
	std::string rdp = arg(argc, argv, "+ramdump=");
	if (!rdp.empty()) {
		FILE *e = fopen(rdp.c_str(), "wb");
		for (uint32_t a = 0; a < 0x200000; a++) fputc((mem[(0xc00000 + a) >> 1] >> (8 * (a & 1))) & 0xff, e);
		fclose(e);
	}
	std::string eep = arg(argc, argv, "+eedump=");
	if (!eep.empty()) {
		FILE *e = fopen(eep.c_str(), "wb");
		auto &ee = top->rootp->tb_lm__DOT__u_main__DOT__u_ee__DOT__mem;
		for (int w = 0; w < 64; w++) { fputc(ee[w] >> 8, e); fputc(ee[w] & 0xff, e); }
		fclose(e);
	}
	std::string nvp = arg(argc, argv, "+nvdump=");
	if (!nvp.empty()) {
		FILE *e = fopen(nvp.c_str(), "wb");
		auto &x = top->rootp->tb_lm__DOT__u_main__DOT__u_x__DOT__mem;
		for (int w = 0; w < 1024; w++)
			for (int b = 3; b >= 0; b--) fputc((x[w] >> (8 * b)) & 0xff, e);
		fclose(e);
	}
	delete top;
	return 0;
}
