// Limenko video bench: one capture frame through lm_video, tiles and sprites.
//
//   run_verilator.sh lm_video_tb +img=<image.bin> +cap=<debug/lmcap/set> +frame=N [+out=f.ppm] [+set=<set>]
//
// +img is the download image (scripts/build_mra_lm.py --image): its graphics from LM_GFX go into the bench's
// graphics array. The capture's VRAMs, palette and video registers (scripts/lm_capture.py) are written through the
// CPU ports. The list the capture's last command drew (f<N>_spr.bin, its count in manifest.txt) goes into bank 1
// and is drawn by a second command, the first having latched the count; after the next interrupt (the swap and the
// tile latch) the next frame is written as a PPM of the visible 384 x 240. Compare with scripts/lm_render_model.py
// (+sprites=0: the tiles alone, scripts/lm_render_model.py --tiles-only).
#include "Vtb_lm_video.h"
#include "Vtb_lm_video___024root.h"
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

static std::vector<uint8_t> slurp(const std::string &p) {
	std::vector<uint8_t> v;
	FILE *f = fopen(p.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(2); }
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	v.resize(n);
	if (fread(v.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read %s\n", p.c_str()); exit(2); }
	fclose(f);
	return v;
}

static uint32_t be32(const std::vector<uint8_t> &v, size_t i) {
	return (v[4 * i] << 24) | (v[4 * i + 1] << 16) | (v[4 * i + 2] << 8) | v[4 * i + 3];
}

int main(int argc, char **argv) {
#ifdef _WIN32
	_fmode = _O_BINARY;
#endif
	Verilated::commandArgs(argc, argv);
	std::string set = arg(argc, argv, "+set=", "dynabomb");
	std::string cap = arg(argc, argv, "+cap=");
	std::string fr = arg(argc, argv, "+frame=");
	std::string outp = arg(argc, argv, "+out=", "f.ppm");
	int sprites = atoi(arg(argc, argv, "+sprites=", "1").c_str());
	std::vector<uint8_t> img = slurp(arg(argc, argv, "+img="));
	const uint32_t LM_GFX = 0xe00000;

	Vtb_lm_video *top = new Vtb_lm_video;
	auto &gfx = top->rootp->tb_lm_video__DOT__gfx;
	for (size_t g = 0; LM_GFX + 8 * g + 8 <= img.size() && g < (1u << 22); g++) {
		uint64_t v = 0;
		for (int k = 0; k < 8; k++) v |= (uint64_t)img[LM_GFX + 8 * g + k] << (8 * k);
		gfx[g] = v;
	}
	// tile counts: the graphics region / 64 (spotty: its expanded 2 MB)
	uint32_t tiles = set == "legendoh" ? 0x48000 : (set == "hrthouse" || set == "spotty") ? 0x8000 : 0x20000;
	top->tile_count = tiles;
	top->tile_pow2 = set != "legendoh";
	top->gfx4 = set == "spotty";
	top->gfx_size = set == "legendoh" ? 0x1200000 : (set == "hrthouse" || set == "spotty") ? 0x200000 : 0x800000;
	top->spr_cmd = 0;

	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	top->rst = 1; top->v0_we = 0; top->v1_we = 0;
	for (int i = 0; i < 8; i++) tick();
	top->rst = 0;

	const std::string p = cap + "/f" + fr;
	std::vector<uint8_t> fg = slurp(p + "_fg.bin"), md = slurp(p + "_md.bin"), bg = slurp(p + "_bg.bin");
	std::vector<uint8_t> pal = slurp(p + "_pal.bin"), vr = slurp(p + "_vreg.bin");
	auto w0 = [&](uint32_t a, uint32_t d) { top->v0_we = 1; top->v0_addr = a; top->v0_wd = d; tick(); top->v0_we = 0; };
	auto w1 = [&](uint32_t a, uint32_t d) { top->v1_we = 1; top->v1_addr = a; top->v1_wd = d; tick(); top->v1_we = 0; };
	for (uint32_t i = 0; i < 0x2000; i++) { w0(i, be32(fg, i)); w0(0x2000 + i, be32(md, i)); w1(i, be32(bg, i)); }
	for (uint32_t i = 0; i < 0x800; i++) w1(0x3000 + i, be32(pal, i));
	for (uint32_t i = 0; i < 5; i++) w1(0x3ffb + i, be32(vr, i));
	if (sprites) {
		uint32_t count = 0;
		{
			FILE *m = fopen((cap + "/manifest.txt").c_str(), "r");
			int fn, c, b, nc;
			while (m && fscanf(m, "%d %d %d %d", &fn, &c, &b, &nc) == 4) if (fn == atoi(fr.c_str())) count = c;
			if (m) fclose(m);
		}
		std::vector<uint8_t> sl = slurp(p + "_spr.bin");
		auto cmd = [&]() { top->spr_cmd = 1; tick(); top->spr_cmd = 0; tick(); while (top->v1_wait) tick(); };
		const uint32_t v0reg = be32(vr, 0);
		w1(0x3ffb, (v0reg & ~0x03ff0000u) | (count << 16));
		cmd();                                   // latches the count; draws bank 0
		for (uint32_t i = 0; i < sl.size() / 4 && i < 1024; i++) w1(0x2400 + i, be32(sl, i));   // bank 1
		w1(0x3ffb, v0reg);
		cmd();                                   // draws bank 1 with the count
		while (!top->vblank_start) tick();
		tick();
	}

	// to the interrupt (the latch), then the next frame's visible pixels
	while (!top->vblank_start) tick();
	while (!top->frame_start) tick();
	std::vector<uint8_t> pix;
	pix.reserve(384 * 240 * 3);
	while (pix.size() < 384 * 240 * 3) {
		tick();
		if (top->ce_pix && !top->hblank && !top->vblank) {
			pix.push_back(top->vid_r); pix.push_back(top->vid_g); pix.push_back(top->vid_b);
		}
	}
	FILE *o = fopen(outp.c_str(), "wb");
	fprintf(o, "P6\n384 240\n255\n");
	fwrite(pix.data(), 1, pix.size(), o);
	fclose(o);
	printf("f%s: %s, overruns %u, sprite draws late %u, sprite lines late %u\n", fr.c_str(), outp.c_str(),
		top->dbg_overrun, top->dbg_spr_late, top->dbg_fb_late);
	delete top;
	return 0;
}
