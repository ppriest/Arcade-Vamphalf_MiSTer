// System bench: the whole board from reset, on the real SDRAM controller and a chip model.
//
//   run_verilator.sh sys_tb +img=<image.bin> +board=0|1 [+frames=N] [+snap=F1,F2,...] [+out=<dir>]
//                    [+pctrace=<instr.trace>] [+coin=F] [+start=F] [+hold=K] [+flip=1] [+v=1]
//
// +img is the download image (scripts/build_mra.py --image <set> <file>); it is written into the
// chip model's array before the clock starts, and a Mission Craft image's EEPROM default (SD_EEPROM)
// goes in through the 93C46 model's load port, as the core's download does. +snap lists frames whose
// visible 320 x 236 pixels are written as <out>/f<N>.ppm. +pctrace compares the CPU's retired PCs with
// a MAME instruction trace (docs/E1_TRACE_FORMAT.md) and reports the first difference: up to the first
// interrupt the two must agree, after it timing differs. +coin / +start press COIN1 / START1 at frame F
// for +hold frames (default 6). +dl=N sends the image's first N bytes through the real download path
// (sdram_download into port 2, one byte per hps_io-style strobe, waiting on ioctl_wait) with the board
// in reset, after the SDRAM's initialisation, and checks the chip model's array against the image.
//
// The sound board's u7 goes in through its download port while the board is in reset. +wave=<file>
// logs its wavetable register writes as scripts/mame_qs1000_wave.py does ("W <tick> <off> <data>", the
// tick a write precedes), so scripts/qs1000_model.py can replay them; +mix=<file> writes every tick's
// left and right sums ("<tick> <l> <r>", the model's --mix format); +wav=<file> the 46.875 kHz output
// the model's --wav computes from the same sums. +prot=<file> logs the FPGA protection's writes and reads
// ("<frame> W|R <port> <data>", as scripts/mame_prot_trace.py captures them from MAME).
//
// Per frame (with +v=1, or every 60 frames): instructions retired, I- and D-cache misses, the video
// engine's overruns and longest line pass.
#include "Vtb_sys.h"
#include "Vtb_sys___024root.h"
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

static const uint32_t SD_EEPROM = 0x180000, SD_SNDCPU = 0x100000;

int main(int argc, char **argv) {
#ifdef _WIN32
	_fmode = _O_BINARY;
#endif
	Verilated::commandArgs(argc, argv);
	std::string imgp = arg(argc, argv, "+img=");
	int board = atoi(arg(argc, argv, "+board=", "0").c_str());
	int family = atoi(arg(argc, argv, "+family=", board ? "1" : "0").c_str());   // the I/O map (vh_main)
	int nframes = atoi(arg(argc, argv, "+frames=", "10").c_str());
	std::string outd = arg(argc, argv, "+out=", ".");
	std::string pctp = arg(argc, argv, "+pctrace=");
	int coin_f = atoi(arg(argc, argv, "+coin=", "-1").c_str());
	int start_f = atoi(arg(argc, argv, "+start=", "-1").c_str());
	int fire_f = atoi(arg(argc, argv, "+fire=", "-1").c_str());   // tap P1 button 1 from this frame, 4 down 4 up
	int coinrep = atoi(arg(argc, argv, "+coinrep=", "0").c_str());
	int hold = atoi(arg(argc, argv, "+hold=", "6").c_str());
	int verbose = atoi(arg(argc, argv, "+v=", "0").c_str());
	int pcwin = atoi(arg(argc, argv, "+pcwin=", "-1").c_str());   // print 200 PCs from this frame
	int pcwin_n = 0;
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
	if (!f) { fprintf(stderr, "cannot open +img=%s\n", imgp.c_str()); return 2; }
	std::vector<uint8_t> img;
	{
		fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
		img.resize(n);
		if (fread(img.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); return 2; }
		fclose(f);
	}

	// MAME instruction trace: the PC of every instruction, in order
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

	Vtb_sys *top = new Vtb_sys;
	auto &mem = top->rootp->tb_sys__DOT__u_chip__DOT__mem;
	size_t dl_n = (size_t)strtoul(arg(argc, argv, "+dl=", "0").c_str(), nullptr, 0);
	for (size_t i = 0; i + 1 < img.size() && i < (32u << 20); i += 2)
		mem[i >> 1] = i < dl_n ? 0x5a5a : (uint16_t)(img[i] | (img[i + 1] << 8));
	top->ioctl_download = 0; top->ioctl_wr = 0; top->snd_dl_we = 0;

	top->clk = 0; top->rst = 1; top->vrst = 1; top->prst = 1; top->board = board; top->pause = 0;
	top->code_mask = board ? 0xffff : 0x7fff;
	top->family = family;
	top->bal_pcb = arg(argc, argv, "+bal=", "mame") == "pcb";   // +bal=pcb: the PCB recording's QS1000 balance
	top->p1p2 = 0xffff; top->system = 0xff; top->flip_osd = atoi(arg(argc, argv, "+flip=", "0").c_str());
	top->ee_blank = 1; top->ee_load_we = 0;
	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };

	for (int i = 0; i < 8; i++) tick();           // the PLL locks: the memory side's power-up reset
	top->prst = 0;
	for (int i = 0; i < 64; i++) tick();          // blank the EEPROM array
	top->ee_blank = 0;
	if (board == 0 && img.size() >= SD_EEPROM + 128) {
		for (int w = 0; w < 64; w++) {
			top->ee_load_we = 1; top->ee_load_addr = w;
			top->ee_load_data = (img[SD_EEPROM + 2 * w] << 8) | img[SD_EEPROM + 2 * w + 1];
			tick();
		}
		top->ee_load_we = 0;
	}
	// +phase=N: the video runs from here, and the CPU leaves reset N clocks later than it would (on the
	// board the video runs through the download, so the CPU starts at an arbitrary line and pixel)
	int phase = atoi(arg(argc, argv, "+phase=", "-1").c_str());
	if (phase >= 0) top->vrst = 0;
	for (int i = 0; i < 3000; i++) tick();        // the SDRAM's initialisation runs under reset
	for (uint32_t a = 0; a < 0x20000; a++) {
		top->snd_dl_we = 1; top->snd_dl_addr = a; top->snd_dl_data = SD_SNDCPU + a < img.size() ? img[SD_SNDCPU + a] : 0xff;
		tick();
	}
	top->snd_dl_we = 0;
	if (dl_n) {
		top->ioctl_download = 1;
		for (int i = 0; i < 16; i++) tick();
		for (size_t a = 0; a < dl_n; a++) {
			top->ioctl_addr = (uint32_t)a; top->ioctl_dout = img[a]; top->ioctl_wr = 1;
			tick();
			top->ioctl_wr = 0;
			do tick(); while (top->ioctl_wait);
			for (int k = 0; k < 4; k++) tick();
		}
		for (int i = 0; i < 16; i++) tick();
		top->ioctl_download = 0;
		for (int i = 0; i < 200; i++) tick();
		size_t bad = 0, first = ~(size_t)0;
		for (size_t i = 0; i + 1 < dl_n; i += 2) {
			uint16_t want = (uint16_t)(img[i] | (img[i + 1] << 8));
			if (mem[i >> 1] != want) { if (first == ~(size_t)0) first = i; bad++; }
		}
		printf("download: %zu bytes through sdram_download, %zu words differ", dl_n, bad);
		if (bad) printf(", first at 0x%zx: %04x, image %02x%02x", first, mem[first >> 1], img[first + 1], img[first]);
		printf("\n");
	}
	for (int i = 0; i < phase; i++) tick();
	top->rst = 0;
	top->vrst = 0;

	uint64_t clocks = 0, retired = 0, ret_frame = 0;
	uint32_t imiss0 = 0, dmiss0 = 0;
	int frame = 0;
	size_t pci = 0;
	bool pc_ok = true;
	std::vector<uint8_t> pix(320 * 236 * 3);
	int npix = 0;
	bool cap = false;
	int latches = 0;
	// +misslog=<file>: every cache miss, "<n> <I|D> <line> <instructions retired before it>" (the board's
	// probe instance T keeps the last 256 of the same list)
	std::string misslog = arg(argc, argv, "+misslog=");
	FILE *mlog = misslog.empty() ? nullptr : fopen(misslog.c_str(), "w");
	int nmiss = 0;
	// +pcfrom=N: print "<k> <npc> <sr>" after instructions N..N+255 (the board's probe instance P)
	long pcfrom = atol(arg(argc, argv, "+pcfrom=", "-1").c_str());
	// +rfslot=N: print "RFW <instructions> <data>" for the first 256 writes to local register slot N
	int rfslot = atoi(arg(argc, argv, "+rfslot=", "-1").c_str());
	int rfw_n = 0;
	// +trace=<file> [+trstart=N]: the 4096 trace records from instruction N (rtl/debug/vh_trace.sv), as
	// "TR <47 hex digits>", the format scripts/read_trace.py dumps from the board
	std::string trp = arg(argc, argv, "+trace=");
	FILE *trf = trp.empty() ? nullptr : fopen(trp.c_str(), "w");
	top->trace_start = (uint32_t)strtoul(arg(argc, argv, "+trstart=", "0").c_str(), nullptr, 0);
	int tr_n = 0;
	uint32_t ni13 = 0;
	// +idle=lo:hi: the game's idle loop. Clocks between two retirements inside it count as idle; a frame
	// with none never reached the loop, so the game lost that frame
	uint32_t idle_lo = 0, idle_hi = 0;
	{
		std::string s = arg(argc, argv, "+idle=");
		if (!s.empty()) sscanf(s.c_str(), "%x:%x", &idle_lo, &idle_hi);
	}
	uint64_t idle_clk = 0, last_ret = 0, fclk0 = 0;
	bool last_idle = false;
	int lost = 0, lost_win = 0;
	double max_busy = 0, max_busy_win = 0;
	// +prof=1: clocks by memory-unit state while the CPU is outside the idle loop (needs +idle)
	int prof = atoi(arg(argc, argv, "+prof=", "0").c_str());
	uint64_t pst[16] = {0}, pidle_req = 0, pnoreq = 0, pfetch = 0, pdata = 0, pwr = 0, pmiss_i = 0, pmiss_d = 0, pwbwait = 0;

	// +rerst=F: hold the core in reset for 2000 clocks at frame F (as probe D's hold bit does on the
	// board) and start the trace over from the release
	int rerst = atoi(arg(argc, argv, "+rerst=", "-1").c_str());
	std::string wavep = arg(argc, argv, "+wave="), mixp = arg(argc, argv, "+mix="), wavp = arg(argc, argv, "+wav=");
	FILE *wvf = wavep.empty() ? nullptr : fopen(wavep.c_str(), "w");
	FILE *mxf = mixp.empty() ? nullptr : fopen(mixp.c_str(), "w");
	std::string protp = arg(argc, argv, "+prot=");
	FILE *ptf = protp.empty() ? nullptr : fopen(protp.c_str(), "w");
	std::vector<int16_t> pcm;
	uint64_t snd_ticks = 0, snd_mixes = 0, snd_writes = 0;
	int64_t acc_l = 0, acc_r = 0;
	auto clamp16 = [](int64_t v) { return (int16_t)(v < -32768 ? -32768 : v > 32767 ? 32767 : v); };
	while (frame < nframes) {
		if (frame == rerst) {
			rerst = -1;
			top->rst = 1;
			for (int i = 0; i < 2000; i++) tick();
			top->rst = 0;
			if (trf) { fclose(trf); trf = fopen(trp.c_str(), "w"); tr_n = 0; }
			printf("core reset at frame %d\n", frame);
		}
		// inputs for this frame
		uint16_t sys = 0xff;
		if (coin_f >= 0 && frame >= coin_f && frame < coin_f + hold) sys &= ~0x01;
		if (start_f >= 0 && frame >= start_f && frame < start_f + hold) sys &= ~0x40;
		top->system = sys;
		top->p1p2 = (fire_f >= 0 && frame >= fire_f && (frame - fire_f) % 8 < 4) ? 0xffef : 0xffff;
		// +coinrep=1: coin at +coin and every 300 frames after, Start 30 frames after each (as the MAME captures)
		if (coinrep && coin_f >= 0 && frame >= coin_f) {
			int k = (frame - coin_f) % 300;
			sys = 0xff;
			if (k < 6) sys &= ~0x01;
			if (k >= 30 && k < 36) sys &= ~0x40;
			top->system = sys;
		}

		tick();
		clocks++;
		if (mlog && top->dbg_miss && nmiss < 200000) {
			fprintf(mlog, "%d %c %06x %u\n", nmiss, top->dbg_miss_ic ? 'I' : 'D', (unsigned)top->dbg_miss_line << 4, ni13);
			nmiss++;
		}
		if (trf && top->trace_valid && tr_n < 4096) {
			fprintf(trf, "TR ");
			for (int w = 5; w >= 0; w--) {
				if (w == 5) fprintf(trf, "%07x", top->trace_rec[w] & 0xfffffff);
				else fprintf(trf, "%08x", top->trace_rec[w]);
			}
			fprintf(trf, "\n");
			tr_n++;
		}
		if (rfslot >= 0 && top->dbg_rf_we && top->dbg_rf_wa == rfslot && rfw_n < 256) {
			printf("RFW %u %08x\n", ni13, top->dbg_rf_wd);
			rfw_n++;
		}
		if (top->retire) {
			if (pcfrom >= 0 && (long)ni13 >= pcfrom && (long)ni13 < pcfrom + 256)
				printf("PCT %u %08x %08x\n", ni13, top->retire_npc, top->retire_sr);
			ni13++;
		}
		if (prof && !last_idle && frame > 100) {
			auto *r = top->rootp;
			int st = r->tb_sys__DOT__u_main__DOT__u_mem__DOT__st;
			bool req = r->tb_sys__DOT__u_main__DOT__u_mem__DOT__bus_req;
			pst[st & 15]++;
			if (!req && st == 1) pnoreq++;
			if (req) {
				if (r->tb_sys__DOT__u_main__DOT__u_mem__DOT__bus_wr) { pwr++; if (st == 1 && r->tb_sys__DOT__u_main__DOT__u_mem__DOT__wb_valid) pwbwait++; }
				else if (r->tb_sys__DOT__u_main__DOT__u_mem__DOT__bus_ifetch) pfetch++;
				else pdata++;
			}
		}
		if (top->retire) {
			retired++;
			bool in_idle = idle_hi && top->retire_pc >= idle_lo && top->retire_pc <= idle_hi;
			if (in_idle && last_idle) idle_clk += clocks - last_ret;
			last_idle = in_idle; last_ret = clocks;
			if (frame == pcwin && pcwin_n < 200) { printf("pc %08x -> %08x\n", top->retire_pc, top->retire_npc); pcwin_n++; }
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
		if (ptf && (top->prot_wr || top->prot_rd))
			fprintf(ptf, "%d %c %04x %08x\n", frame, top->prot_wr ? 'W' : 'R', top->prot_tab16 ? 0x0d0 : 0x1a0,
				top->prot_wr ? top->prot_wd : top->prot_rdata);
		if (top->snd_wave_wr) {
			if (wvf) fprintf(wvf, "W %llu %02x %02x\n", (unsigned long long)snd_ticks, top->snd_wave_off, top->snd_wave_data);
			snd_writes++;
		}
		if (top->snd_tick) snd_ticks++;
		if (top->snd_mix_valid) {
			int32_t l = (int32_t)top->snd_mix_l, r = (int32_t)top->snd_mix_r;
			if (mxf) fprintf(mxf, "%llu %d %d\n", (unsigned long long)snd_mixes, l, r);
			acc_l += l; acc_r += r;
			if ((snd_mixes & 15) == 15) {
				pcm.push_back(clamp16((acc_l >> 4) >> 12)); pcm.push_back(clamp16((acc_r >> 4) >> 12));
				acc_l = acc_r = 0;
			}
			snd_mixes++;
		}
		if (top->snd_latch_wr && wvf)
			fprintf(wvf, "L %llu %x\n", (unsigned long long)snd_ticks, top->snd_latch);
		if (top->snd_latch_wr) {
			if (latches < 40) printf("frame %d: sound latch %02x\n", frame, top->snd_latch);
			latches++;
		}
		if (cap && top->ce_pix && !top->hblank && !top->vblank) {
			if (npix < 320 * 236) {
				pix[3 * npix] = top->vid_r; pix[3 * npix + 1] = top->vid_g; pix[3 * npix + 2] = top->vid_b;
			}
			npix++;
		}
		if (top->frame_start) {
			if (cap) {
				char fn[512];
				snprintf(fn, sizeof fn, "%s/f%d.ppm", outd.c_str(), frame - 1);
				FILE *o = fopen(fn, "wb");
				if (o) { fprintf(o, "P6\n320 236\n255\n"); fwrite(pix.data(), 1, pix.size(), o); fclose(o); }
				cap = false;
			}
			if (idle_hi && frame > 100) {
				double busy = 1.0 - (double)idle_clk / (double)(clocks - fclk0);
				if (idle_clk == 0) { lost++; lost_win++; }
				if (busy > max_busy) max_busy = busy;
				if (busy > max_busy_win) max_busy_win = busy;
			}
			if (verbose || frame % 60 == 0) {
				printf("frame %5d: %7llu instructions, imiss %u dmiss %u, overruns %u, longest pass %u, flip %d",
					frame, (unsigned long long)(retired - ret_frame), top->st_imiss - imiss0,
					top->st_dmiss - dmiss0, top->dbg_overrun, top->dbg_maxbusy, top->game_flip);
				if (idle_hi) printf(", busiest %.0f%%, frames without idle %d", 100 * max_busy_win, lost_win);
				printf("\n");
				max_busy_win = 0; lost_win = 0;
			}
			idle_clk = 0; fclk0 = clocks;
			fflush(stdout);
			if (verbose) {
				auto &G = top->rootp->tb_sys__DOT__u_main__DOT__u_cpu__DOT__G;
				printf("      sr %08x fcr %08x tpr %08x isr %08x int2 %d\n", top->rootp->tb_sys__DOT__u_main__DOT__u_cpu__DOT__sr,
					G[26], G[21], G[25], top->rootp->tb_sys__DOT__u_main__DOT__int2);
			}
			ret_frame = retired; imiss0 = top->st_imiss; dmiss0 = top->st_dmiss;
			frame++;
			if (snaps.count(frame)) { cap = true; npix = 0; }
		}
	}
	if (prof) {
		uint64_t t = 0;
		for (int i = 0; i < 16; i++) t += pst[i];
		static const char *nm[] = {"INIT", "IDLE", "LOOK", "WLOOK", "MISS", "FILL", "FILL2", "ACK"};
		printf("profile, %llu busy clocks:", (unsigned long long)t);
		for (int i = 0; i < 8; i++) printf(" %s %.1f%%", nm[i], 100.0 * pst[i] / t);
		printf("; store waiting for the write buffer %.1f%%", 100.0 * pwbwait / t);
		printf("; no request %.1f%%; bus held by fetch %.1f%% data read %.1f%% write %.1f%%\n",
			100.0 * pnoreq / t, 100.0 * pfetch / t, 100.0 * pdata / t, 100.0 * pwr / t);
	}
	if (ptf) fclose(ptf);
	if (wvf) fclose(wvf);
	if (mxf) fclose(mxf);
	if (!wavp.empty()) {
		FILE *o = fopen(wavp.c_str(), "wb");
		if (o) {
			uint32_t rate = 750000 / 16, n = (uint32_t)(pcm.size() * 2), v;
			fwrite("RIFF", 1, 4, o); v = 36 + n; fwrite(&v, 4, 1, o); fwrite("WAVEfmt ", 1, 8, o);
			v = 16; fwrite(&v, 4, 1, o);
			uint16_t h[2] = {1, 2}; fwrite(h, 2, 2, o);
			fwrite(&rate, 4, 1, o); v = rate * 4; fwrite(&v, 4, 1, o);
			h[0] = 4; h[1] = 16; fwrite(h, 2, 2, o);
			fwrite("data", 1, 4, o); fwrite(&n, 4, 1, o); fwrite(pcm.data(), 2, pcm.size(), o);
			fclose(o);
		}
	}
	printf("sound: %llu ticks, %llu sums, %llu wavetable writes, queue drops %u, pipeline stalls %u\n",
		(unsigned long long)snd_ticks, (unsigned long long)snd_mixes, (unsigned long long)snd_writes,
		top->snd_drops, top->snd_stalls);
	if (idle_hi) printf("idle loop: busiest frame %.1f%% busy, %d frames (after 100) never reached it\n", 100 * max_busy, lost);
	printf("done: %d frames, %llu clocks, %llu instructions (%.2f clocks each), %d sound latch writes\n",
		frame, (unsigned long long)clocks, (unsigned long long)retired,
		retired ? (double)clocks / retired : 0.0, latches);
	delete top;
	return 0;
}
