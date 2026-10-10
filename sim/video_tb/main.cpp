// Video RTL (vh_video) against MAME dumps.
//
//   run_verilator.sh video_tb +dir=<capture dir> +frame=<N> +gfx=<gfx.bin> +out=<file.ppm>
//                    [+flip=0|1] [+lat=<clocks>] [+frames=<k>]
//
// Loads f<N>_spriteram.bin and f<N>_palette.bin (big-endian u16, as scripts/vamphalf_capture.py
// dumps them) through the CPU ports, serves the graphics ROM from gfx.bin with +lat clocks of
// latency and one 32-bit beat per clock, runs the video for +frames frames (default 3) and
// writes the visible pixels of the last frame as a binary PPM. scripts/video_check.py compares
// the PPM with the software model.
#include "Vtb_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::string arg(int argc, char **argv, const char *key, const char *def = "") {
	size_t n = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, n)) return std::string(argv[i] + n);
	return def;
}

static std::vector<uint8_t> slurp(const std::string &p) {
	std::vector<uint8_t> v;
	FILE *f = fopen(p.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(2); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	v.resize(n);
	if (fread(v.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read %s\n", p.c_str()); exit(2); }
	fclose(f);
	return v;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::string dir = arg(argc, argv, "+dir=");
	std::string frame = arg(argc, argv, "+frame=");
	std::string gfxp = arg(argc, argv, "+gfx=");
	std::string outp = arg(argc, argv, "+out=", "video.ppm");
	int flip = atoi(arg(argc, argv, "+flip=", "0").c_str());
	int lat = atoi(arg(argc, argv, "+lat=", "6").c_str());
	int nframes = atoi(arg(argc, argv, "+frames=", "3").c_str());
	int aoh = atoi(arg(argc, argv, "+aoh=", "0").c_str());   // aoh's timing and sprite format: 384 x 224
	const int vw = aoh ? 384 : 320, vh = aoh ? 224 : 236;

	std::vector<uint8_t> spr = slurp(dir + "/f" + frame + "_spriteram.bin");
	std::vector<uint8_t> pal = slurp(dir + "/f" + frame + "_palette.bin");
	std::vector<uint8_t> gfx = slurp(gfxp);

	Vtb_video *t = new Vtb_video;
	auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
	t->clk = 0; t->rst = 1; t->spr_we = 0; t->pal_we = 0; t->gfx_dv = 0; t->gfx_rdy = 1; t->flip = flip; t->code_mask = 0xffff;
	t->palshift = 0; t->aoh = aoh;
	for (int i = 0; i < 4; i++) tick();
	t->rst = 0;

	// CPU writes: the palette first, the sprite list last in ascending order (its last dword ends the pass)
	auto dword = [&](const std::vector<uint8_t> &m, int n) {
		return ((uint32_t)m[4 * n] << 24) | ((uint32_t)m[4 * n + 1] << 16) | ((uint32_t)m[4 * n + 2] << 8) | m[4 * n + 3];
	};
	for (int n = 0; n < 16384; n++) {
		t->pal_we = 1; t->pal_be = 0xf; t->pal_addr = n; t->pal_wd = dword(pal, n);
		tick();
	}
	t->pal_we = 0;
	for (int n = 0; n < 16384; n++) {
		t->spr_we = 1; t->spr_be = 0xf; t->spr_addr = n; t->spr_wd = dword(spr, n);
		tick();
	}
	t->spr_we = 0;

	// graphics ROM model: request -> four beats after lat clocks
	struct Req { int wait; uint32_t addr; int beat; };
	std::vector<Req> q;
	std::vector<uint8_t> img;            // pixels of the last captured frame, 320 x 236 RGB
	std::vector<uint8_t> cur;
	int frames_seen = 0;
	int cur_pix = 0, cur_rows = 0;
	bool in_frame_capture = false;
	uint64_t clocks = 0;
	int lineno_prev = -1;

	while (frames_seen < nframes + 1 && clocks < 200000000ull) {
		// serve the ROM
		t->gfx_dv = 0;
		if (t->gfx_req) q.push_back({lat, (uint32_t)t->gfx_addr, 0});
		for (auto &r : q) {
			if (r.wait > 0) { r.wait--; continue; }
			if (r.beat < 4) {
				uint32_t a = r.addr + 4 * r.beat;
				uint32_t v = 0;
				if (a + 3 < gfx.size()) v = ((uint32_t)gfx[a] << 24) | ((uint32_t)gfx[a + 1] << 16) | ((uint32_t)gfx[a + 2] << 8) | gfx[a + 3];
				t->gfx_dv = 1; t->gfx_data = v;
				r.beat++;
				break;   // one beat per clock overall
			}
		}
		while (!q.empty() && q.front().beat >= 4) q.erase(q.begin());

		tick();
		clocks++;
		if (t->frame_start) {
			frames_seen++;
			if (frames_seen == nframes) { cur.assign(vw * vh * 3, 0); cur_pix = 0; in_frame_capture = true; }
			else if (frames_seen == nframes + 1) { img = cur; in_frame_capture = false; }
		}
		if (t->ce_pix && in_frame_capture && !t->hblank && !t->vblank) {
			if (cur_pix < vw * vh) {
				cur[3 * cur_pix] = t->vid_r; cur[3 * cur_pix + 1] = t->vid_g; cur[3 * cur_pix + 2] = t->vid_b;
			}
			cur_pix++;
		}
	}
	(void)lineno_prev; (void)cur_rows;
	if (img.empty()) { fprintf(stderr, "no frame captured\n"); return 3; }
	FILE *f = fopen(outp.c_str(), "wb");
	fprintf(f, "P6\n%d %d\n255\n", vw, vh);
	fwrite(img.data(), 1, img.size(), f);
	fclose(f);
	printf("frame %s flip %d: %d pixel slots captured, engine overruns %d, longest pass %d of 3584 clocks, %llu clocks\n", frame.c_str(), flip, cur_pix, (int)t->dbg_overrun, (int)t->dbg_maxbusy, (unsigned long long)clocks);
	delete t;
	return 0;
}
