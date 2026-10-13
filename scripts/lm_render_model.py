#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Software model of the Limenko video (limenko.cpp screen_update, draw_sprites, copy_sprites), checked against
MAME's screenshots from scripts/lm_capture.py.

    python scripts/lm_render_model.py <set> [--tag _play] [--frames 600,750] [--out DIR] [--tiles-only]

Reads debug/lmcap/<set><tag>/ and the set's download image (debug/lm/<set>.bin, scripts/build_mra_lm.py
--image) for the graphics. Per frame: the pixels that differ from MAME's f<N>.png. --out writes the model's
frames (and with --tiles-only the tile layers alone, for the video bench's step 3 check).

The model, from the driver:
  tilemaps   128 x 64 tiles of 8 x 8, 8bpp (gfx_8x8x8_raw), TILEMAP_SCAN_ROWS; entry: tile = bits 18:0 (modulo
             the graphics' tile count), colour = bits 31:28; palette entry colour * 256 + pen. Scroll x = register
             bits 31:16, y = bits 15:0, wrapping at 1024 x 512. bg is opaque, md and fg skip pen 0. Drawn bg, md,
             fg when enabled (register 0 bits 2, 1, 0); fg's opaque pixels set screen priority 1.
  sprites    the list drawn at the last command into a 512 x 512 bitmap (and its priority bitmap), drawn at x, y,
             x - 512, y - 512; a pixel is written where the bitmap's priority is below the sprite's (1 below fg,
             2 above all): the first sprite wins within a priority. Copied over the tiles where the screen
             priority is below the pixel's, when register 0 bit 3 is set.
  colour     xBGR555, pal5bit.
A frame whose bg layer is off is drawn over the previous frame's picture in MAME (the bitmap is not cleared);
the model draws it over black and says so.
"""
import argparse
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
GFX_LEN = {"dynabomb": 0x800000, "sb2003": 0x800000, "sb2003a": 0x800000, "legendoh": 0x1200000,
           "hrthouse": 0x200000, "spotty": 0x200000}


def lm_map():
    text = (REPO / "rtl" / "lm_sdram_map.svh").read_text()
    return dict((k, int(v, 16)) for k, v in re.findall(r"localparam \[26:0\] (LM_\w+)\s*=\s*27'h([0-9a-fA-F]+);", text))


def load_gfx(setname):
    img = (REPO / "debug" / "lm" / f"{setname}.bin").read_bytes()
    base = lm_map()["LM_GFX"]
    if setname == "spotty":
        g = np.frombuffer(img[base:base + 0x100000], dtype=np.uint8)
        out = np.empty(0x200000, dtype=np.uint8)
        out[0::2] = g & 0x0f
        out[1::2] = g >> 4
        return out
    return np.frombuffer(img[base:base + GFX_LEN[setname]], dtype=np.uint8)


def be32(path):
    return np.frombuffer(Path(path).read_bytes(), dtype=">u4").astype(np.uint32)


def tile_layer(vram, scroll, gfx):
    """Per screen pixel: the palette index (colour * 256 + pen) and the pen."""
    sx, sy = (scroll >> 16) & 0xffff, scroll & 0xffff
    ys = (np.arange(240)[:, None] + sy) & 511
    xs = (np.arange(384)[None, :] + sx) & 1023
    entry = vram[(ys >> 3) * 128 + (xs >> 3)]
    code = (entry & 0x7ffff) % (len(gfx) // 64)
    pen = gfx[code * 64 + (ys & 7) * 8 + (xs & 7)].astype(np.uint32)
    return ((entry >> 28) & 0xf) * 256 + pen, pen


def sprite_bitmap(words, gfx):
    bmp = np.zeros((512, 512), dtype=np.uint32)
    pri = np.zeros((512, 512), dtype=np.uint8)
    for i in range(0, len(words) - 1, 2):
        w0, w1 = int(words[i]), int(words[i + 1])
        if not w0 & 0x80000000:
            continue
        x = (w0 >> 16) & 0x1ff
        w = (((w0 >> 25) & 7) + 1) * 8
        flipx = bool(w0 & 0x10000000)
        y = w0 & 0x1ff
        h = (((w0 >> 9) & 7) + 1) * 8
        flipy = bool(w0 & 0x1000)
        code = (w1 & 0x7ffff) << 6
        color = (w1 >> 28) & 0xf
        p = 1 if w1 & 0x04000000 else 2
        if code + w * h > len(gfx):
            continue
        src = gfx[code:code + w * h].reshape(h, w)
        if flipx:
            src = src[:, ::-1]
        if flipy:
            src = src[::-1, :]
        for ox in (x, x - 512):
            for oy in (y, y - 512):
                x0, x1 = max(ox, 0), min(ox + w, 512)
                y0, y1 = max(oy, 0), min(oy + h, 512)
                if x1 <= x0 or y1 <= y0:
                    continue
                s = src[y0 - oy:y1 - oy, x0 - ox:x1 - ox]
                pr = pri[y0:y1, x0:x1]
                m = (s != 0) & (pr < p)
                bmp[y0:y1, x0:x1][m] = color * 256 + s[m].astype(np.uint32)
                pr[m] = p
    return bmp, pri


def palette_rgb(pal_words):
    ent = np.empty(0x1000, dtype=np.uint32)
    ent[0::2] = pal_words >> 16
    ent[1::2] = pal_words & 0xffff
    r, g, b = ent & 0x1f, (ent >> 5) & 0x1f, (ent >> 10) & 0x1f
    p5 = lambda v: ((v << 3) | (v >> 2)).astype(np.uint8)  # noqa: E731
    return np.stack([p5(r), p5(g), p5(b)], axis=-1)


def render(cap, n, gfx, tiles_only=False):
    vreg = be32(cap / f"f{n}_vreg.bin")
    rgb = palette_rgb(be32(cap / f"f{n}_pal.bin"))
    idx = np.zeros((240, 384), dtype=np.uint32)
    scr_pri = np.zeros((240, 384), dtype=np.uint8)
    note = ""
    if not vreg[0] & 4:
        note = "bg off: MAME draws over the previous frame"
    for name, bit, reg, opaque, prio in (("bg", 4, 3, True, 0), ("md", 2, 2, False, 0), ("fg", 1, 1, False, 1)):
        if not vreg[0] & bit:
            continue
        li, pen = tile_layer(be32(cap / f"f{n}_{name}.bin"), int(vreg[reg]), gfx)
        m = np.ones_like(pen, dtype=bool) if opaque else pen != 0
        idx[m] = li[m]
        scr_pri[m] = prio
    if not tiles_only and vreg[0] & 8:
        bmp, spri = sprite_bitmap(be32(cap / f"f{n}_spr.bin"), gfx)
        sb, sp = bmp[:240, :384], spri[:240, :384]
        m = (sb != 0) & (scr_pri < sp)
        idx[m] = sb[m]
    return rgb[idx], note


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--tag", default="")
    ap.add_argument("--frames", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--tiles-only", action="store_true")
    a = ap.parse_args()
    cap = REPO / "debug" / "lmcap" / f"{a.set}{a.tag}"
    gfx = load_gfx(a.set)
    frames = [int(x) for x in a.frames.split(",")] if a.frames else \
        [int(ln.split()[0]) for ln in (cap / "manifest.txt").read_text().splitlines() if ln.strip()]
    out = Path(a.out) if a.out else None
    if out:
        out.mkdir(parents=True, exist_ok=True)
    bad = 0
    for n in frames:
        pic, note = render(cap, n, gfx, a.tiles_only)
        if out:
            Image.fromarray(pic).save(out / f"f{n}.png")
        if a.tiles_only:
            continue
        mame = np.asarray(Image.open(cap / f"f{n}.png").convert("RGB"))
        diff = int(np.any(pic != mame, axis=-1).sum()) if mame.shape == pic.shape else -1
        bad += diff != 0
        print(f"{a.set}{a.tag} f{n}: {diff} pixels differ" + (f" ({note})" if note else ""))
    if not a.tiles_only:
        print(f"{a.set}{a.tag}: {len(frames) - bad} of {len(frames)} frames pixel-identical to MAME")
    return 0


if __name__ == "__main__":
    sys.exit(main())
