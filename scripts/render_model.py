#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Software model of the Vamphalf video (MAME vamphalf.cpp draw_sprites), checked against MAME.

    python scripts/render_model.py compare debug/vcap/misncrft [debug/vcap/misncrft_attract ...]
                                    [--write-ref sim/ref/misncrft/video]
    python scripts/render_model.py census  debug/vcap/misncrft ... [--out docs/SPRITE_CENSUS.txt]
    python scripts/render_model.py lines   debug/vcap/misncrft 3000 [--line 120]

Input per frame: f<N>_spriteram.bin (256 KB), f<N>_palette.bin (64 KB), the flip state from
manifest.txt, and gfx.bin (the "gfx" region) in the same directory or in the first directory given.
Produced by scripts/vamphalf_capture.py. `compare` renders every frame and compares pixel for pixel
with MAME's f<N>.png.

The model is MAME's loop, not a hardware structure: 17 bands of 0x800 bytes of sprite RAM, a band
per 16-line strip, sprites in list order, later over earlier, pen 0 transparent. render() also
returns, per output line, the ordered list of (sprite index, band, opaque pixels) that touch it,
which is what a per-scanline engine has to reproduce.
"""
import argparse
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image

W_TOTAL, H_TOTAL = 448, 264
X_MIN, X_MAX = 31, 350            # HBEND .. HBSTART-1
Y_UNFLIPPED = (16, 251)           # VBEND .. VBSTART-1
Y_FLIPPED = (20, 255)             # handle_flipped_visible_area
BAND_BYTES = 0x800
FLIP_X = 366                      # x = 366 - x when flipped


def visarea(flip):
    y0, y1 = Y_FLIPPED if flip else Y_UNFLIPPED
    return X_MIN, X_MAX, y0, y1


def pal5bit(v):
    return (v << 3) | (v >> 2)


def palette_table(pal_u16):
    """xRGB_555 -> 8-bit RGB, MAME palette_device (pal5bit per channel); bit 15 unused."""
    p = pal_u16.astype(np.uint32)
    t = np.zeros((len(p), 3), np.uint8)
    t[:, 0] = pal5bit((p >> 10) & 31)
    t[:, 1] = pal5bit((p >> 5) & 31)
    t[:, 2] = pal5bit(p & 31)
    return t


class Model:
    def __init__(self, gfx):
        self.gfx = np.asarray(gfx, dtype=np.uint8)
        self.elements = len(self.gfx) // 256          # gfx_element::elements(): codes wrap modulo this

    def render(self, spr, pal, flip, clip_flip=None, collect=True, bitmap=None):
        """spr: 0x20000 u16 (sprite RAM as the CPU sees it), pal: 0x8000 u16.

        flip: m_flipscreen at this update. clip_flip: flip state the screen's visible area held when
        screen_update was called (MAME changes the area inside screen_update, so the clip lags by one
        update); default = flip. bitmap: the screen bitmap left by the previous update (modified in
        place); MAME fills only the clip, so rows outside it keep what an earlier update drew there.
        Returns dict: pens (264x448 u16), rgb (crop of the visible area after this update),
        lines {y: [(idx, band, opaque, vis_x)]}, drawn (list of per-sprite tuples).
        """
        clip = visarea(flip if clip_flip is None else clip_flip)
        cx0, cx1, cy0, cy1 = clip
        pens = np.zeros((H_TOTAL, W_TOTAL), np.uint16) if bitmap is None else bitmap
        pens[cy0:cy1 + 1, cx0:cx1 + 1] = 0                      # bitmap.fill(0, cliprect)
        lines = {} if collect else None
        drawn = []
        for sy in range(cy0 & ~15, (cy1 | 15) + 1, 16):
            s0, s1 = max(sy, cy0), min(sy + 15, cy1)
            band = (sy // 16) * 0x800 if flip else (16 - sy // 16) * 0x800
            for cnt in range(0, 0x800, 8):
                o = (band + cnt) // 2
                w0 = int(spr[o])
                if w0 & 0x100:
                    continue
                code = int(spr[o + 1])
                color = int(spr[o + 2]) & 0x7f
                x = int(spr[o + 3]) & 0x1ff
                y = 256 - (w0 & 0xff)
                fx, fy = bool(w0 & 0x8000), bool(w0 & 0x4000)
                if flip:
                    fx, fy = not fx, not fy
                    x = FLIP_X - x
                    y = 256 - y
                idx = cnt // 8
                got = self._blit(pens, (cx0, cx1, s0, s1), code, color, fx, fy, x, y)
                if got is None:
                    continue
                ys, opaque, vis_x = got
                drawn.append((band // 0x800, idx, code, x, y, fx, fy, color))
                if collect:
                    for k, yy in enumerate(ys):
                        lines.setdefault(yy, []).append((idx, band // 0x800, int(opaque[k]), vis_x))
        vx0, vx1, vy0, vy1 = visarea(flip)
        rgb = palette_table(pal)[pens[vy0:vy1 + 1, vx0:vx1 + 1]]
        return {"pens": pens, "rgb": rgb, "lines": lines, "drawn": drawn, "clip": clip}

    def _blit(self, pens, clip, code, color, fx, fy, x, y):
        cx0, cx1, cy0, cy1 = clip
        x0, x1 = max(x, cx0), min(x + 15, cx1)
        y0, y1 = max(y, cy0), min(y + 15, cy1)
        if x0 > x1 or y0 > y1:
            return None
        c = code % self.elements
        tile = self.gfx[c * 256:(c + 1) * 256].reshape(16, 16)
        if fy:
            tile = tile[::-1]
        if fx:
            tile = tile[:, ::-1]
        sub = tile[y0 - y:y1 - y + 1, x0 - x:x1 - x + 1]
        m = sub != 0
        dst = pens[y0:y1 + 1, x0:x1 + 1]
        dst[m] = (color * 256 + sub[m].astype(np.uint16)).astype(np.uint16)
        return list(range(y0, y1 + 1)), m.sum(axis=1), x1 - x0 + 1


# ---- capture directories -------------------------------------------------------------------

def read_manifest(d):
    frames = []
    for line in (Path(d) / "manifest.txt").read_text().splitlines():
        f = line.split()
        if f and f[0].isdigit():
            frames.append({"frame": int(f[0]), "flip": int(f[1]), "clipflip": int(f[2]),
                           "w": int(f[3]), "h": int(f[4])})
    return frames


def find_gfx(dirs):
    """gfx.bin of the first directory that has one, else of <set>_attract next to it (the capture
    that dumped it, scripts/vamphalf_capture.py --gfx)."""
    for d in dirs:
        d = Path(d)
        for c in (d, d.parent / (d.name.split("_")[0] + "_attract")):
            if (c / "gfx.bin").exists():
                return c / "gfx.bin"
    sys.exit("no gfx.bin in " + ", ".join(map(str, dirs)))


def load_frame(d, fn):
    spr = np.fromfile(Path(d) / f"f{fn}_spriteram.bin", dtype=">u2").astype(np.uint16)
    pal = np.fromfile(Path(d) / f"f{fn}_palette.bin", dtype=">u2").astype(np.uint16)
    return spr, pal


ORIENT = {
    "none": lambda im: im,
    "rot180": lambda im: im[::-1, ::-1],
    "flipud": lambda im: im[::-1],
    "fliplr": lambda im: im[:, ::-1],
}


def detect_orientation(model, d, frames):
    """Which transform of the model output equals MAME's -snapview native snapshot.

    Measured on the first frame with sprites: ROT270 sets (wivernwg) are snapshotted turned 180 degrees
    from the bitmap, ROT90 sets (misncrft) are not. The result is then pinned for every frame.
    """
    m = frames[0]
    spr, pal = load_frame(d, m["frame"])
    ref = np.asarray(Image.open(d / f"f{m['frame']}.png").convert("RGB"))
    r = model.render(spr, pal, m["flip"], clip_flip=m["clipflip"], collect=False)["rgb"]
    score = {k: int((f(r) != ref).any(axis=2).sum()) for k, f in ORIENT.items() if f(r).shape == ref.shape}
    return min(score, key=score.get), score


def cmd_compare(a):
    dirs = [Path(d) for d in a.dirs]
    model = Model(np.fromfile(find_gfx(dirs), dtype=np.uint8))
    tot_f = tot_ok = 0
    orient, oscore = detect_orientation(model, dirs[0], read_manifest(dirs[0]))
    print(f"snapshot orientation: {orient} (first-frame mismatch px per transform: {oscore})")
    tf = ORIENT[orient]
    results = []
    for d in dirs:
        frames = read_manifest(d)
        bitmap = np.zeros((H_TOTAL, W_TOTAL), np.uint16)
        for m in frames:
            fn, flip, cflip = m["frame"], m["flip"], m["clipflip"]
            spr, pal = load_frame(d, fn)
            ref = np.asarray(Image.open(d / f"f{fn}.png").convert("RGB"))
            r = model.render(spr, pal, flip, clip_flip=cflip, collect=False, bitmap=bitmap)
            r["rgb"] = tf(r["rgb"])
            n_bad = -1 if r["rgb"].shape != ref.shape else int((r["rgb"] != ref).any(axis=2).sum())
            name = "lag" if cflip != flip else "same"
            ndraw = len(r["drawn"])
            results.append((d.name, fn, flip, ref.shape[1], ref.shape[0], n_bad, name, ndraw))
            tot_f += 1
            tot_ok += n_bad == 0
            print(f"{d.name:22s} frame {fn:5d} flip {flip} {ref.shape[1]}x{ref.shape[0]} "
                  f"sprites {ndraw:4d} mismatch px {n_bad:6d}  {'OK' if n_bad == 0 else 'DIFF'}"
                  + (" (clip lags: flip changed since the previous update)" if name == "lag" else ""))
            if n_bad and a.diff_dir:
                Path(a.diff_dir).mkdir(parents=True, exist_ok=True)
                bad = (r["rgb"] != ref).any(axis=2)
                out = np.zeros(ref.shape, np.uint8)
                out[bad] = (255, 0, 255)
                Image.fromarray(np.concatenate([ref, r["rgb"], out], axis=1)).save(
                    Path(a.diff_dir) / f"{d.name}_f{fn}.png")
    print(f"{tot_ok}/{tot_f} frames pixel-identical")
    if a.write_ref:
        ref_dir = Path(a.write_ref)
        ref_dir.mkdir(parents=True, exist_ok=True)
        lines = ["# " + n for n in a.note]
        for d in dirs:
            man = (d / "manifest.txt").read_text().splitlines()
            lines += [f"# capture {d.name}"] + [l for l in man if not l.startswith("gfx ")]
            for m in read_manifest(d):
                shutil.copyfile(d / f"f{m['frame']}.png", ref_dir / f"{d.name}_f{m['frame']}.png")
        lines += [f"# snapshot orientation relative to the model bitmap: {orient}",
                  "# render_model.py compare: dir frame flip mismatch_px(clip)"]
        lines += [f"{n} {f} {fl} {bad} {cl}" for n, f, fl, _, _, bad, cl, _ in results]
        lines += [f"# {tot_ok}/{tot_f} frames pixel-identical"]
        (ref_dir / "manifest.txt").write_text("\n".join(lines) + "\n")
    return 0 if tot_ok == tot_f else 1


# ---- census --------------------------------------------------------------------------------

def frame_stats(model, spr, flip, clip_flip=None):
    """Per-frame figures; per-line arrays are indexed by output line (bitmap y)."""
    clip = visarea(flip if clip_flip is None else clip_flip)
    cx0, cx1, cy0, cy1 = clip
    nl = H_TOTAL
    n_band = np.zeros(nl, int)       # non-hidden sprites in the line's band
    n_y = np.zeros(nl, int)          # ... whose 16 rows cover the line (strip-clipped)
    n_vis = np.zeros(nl, int)        # ... and whose x range touches the visible columns
    opaque = np.zeros(nl, int)       # opaque pixels drawn on the line, before overdraw
    codes = []
    band_active, band_hi, parked = [], [], {}
    for sy in range(cy0 & ~15, (cy1 | 15) + 1, 16):
        s0, s1 = max(sy, cy0), min(sy + 15, cy1)
        band = (sy // 16) * 0x800 if flip else (16 - sy // 16) * 0x800
        base = band // 2
        e = spr[base:base + 0x400].reshape(256, 4)
        keep = (e[:, 0] & 0x100) == 0
        n_band[s0:s1 + 1] = keep.sum()
        act = []
        for i in np.nonzero(keep)[0]:
            w0, code, col, xw = (int(v) for v in e[i])
            x = xw & 0x1ff
            y = 256 - (w0 & 0xff)
            fx, fy = bool(w0 & 0x8000), bool(w0 & 0x4000)
            if flip:
                fx, fy = not fx, not fy
                x, y = FLIP_X - x, 256 - y
            ya, yb = max(y, s0), min(y + 15, s1)
            xa, xb = max(x, cx0), min(x + 15, cx1)
            if ya <= yb:
                n_y[ya:yb + 1] += 1
                codes.append(code)
            if ya > yb or xa > xb:
                parked[(w0, x)] = parked.get((w0, x), 0) + 1       # no visible pixel in this strip
                continue
            act.append(int(i))
            n_vis[ya:yb + 1] += 1
            c = code % model.elements
            tile = model.gfx[c * 256:(c + 1) * 256].reshape(16, 16)
            tile = tile[::-1] if fy else tile
            tile = tile[:, ::-1] if fx else tile
            sub = tile[ya - y:yb - y + 1, xa - x:xb - x + 1]
            opaque[ya:yb + 1] += (sub != 0).sum(axis=1)
        band_active.append(len(act))
        band_hi.append(max(act) if act else -1)
    return {"band_active": band_active, "band_hi": band_hi, "parked": parked, "n_band": n_band, "n_y": n_y, "n_vis": n_vis, "opaque": opaque, "codes": codes,
            "clip": clip}


def cmd_census(a):
    dirs = [Path(d) for d in a.dirs]
    model = Model(np.fromfile(find_gfx(dirs), dtype=np.uint8))
    out = []
    P = out.append
    agg = {"n_band": [], "n_y": [], "n_vis": [], "opaque": []}
    codes_all = []
    per_frame = []
    beyond = []
    unused_bands = []
    dup = []
    act_max, hi_max, parked_all = 0, -1, {}
    for d in dirs:
        for m in read_manifest(d):
            fn, flip = m["frame"], m["flip"]
            spr, _ = load_frame(d, fn)
            st = frame_stats(model, spr, flip, m["clipflip"])
            act_max = max(act_max, max(st["band_active"]))
            hi_max = max(hi_max, max(st["band_hi"]))
            for k, v in st["parked"].items():
                parked_all[k] = parked_all.get(k, 0) + v
            _, _, y0, y1 = st["clip"]
            sl = slice(y0, y1 + 1)
            for k in agg:
                agg[k].append(st[k][sl])
            codes_all += st["codes"]
            nz_rest = int(np.count_nonzero(spr[0x4400:]))        # words past the 17 bands (0x8800 bytes)
            band_nz = [int(np.count_nonzero(spr[b * 0x400:(b + 1) * 0x400])) for b in range(17)]
            beyond.append(nz_rest)
            unused_bands.append((band_nz[0], band_nz[16]))
            cs = np.array(st["codes"]) if st["codes"] else np.zeros(0, int)
            u, c = np.unique(cs, return_counts=True)
            dup.append((len(cs), len(u), int(c.max()) if len(c) else 0, int((c[c > 1]).sum())))
            per_frame.append((d.name, fn, flip, int(st["n_band"][sl].max()), int(st["n_y"][sl].max()),
                              int(st["n_vis"][sl].max()), int(st["opaque"][sl].max()),
                              int(st["n_y"][sl].sum()), int(max(st["codes"]) if st["codes"] else 0)))
    A = {k: np.concatenate(v) for k, v in agg.items()}
    P(f"Sprite census: {len(per_frame)} frames from {', '.join(d.name for d in dirs)}")
    P(f"gfx region {len(model.gfx)} bytes = {model.elements} codes")
    P("")
    P("Per-frame maxima over the visible lines (n_band = non-hidden sprites in the line's band;")
    P("n_y = of those, covering the line after strip clipping; n_vis = and x-visible; opaque = pixels")
    P("with pen != 0 before overdraw; sprite_lines = sum over lines of n_y; maxcode = largest code of a")
    P("sprite that covers some line):")
    P(f"{'capture':22s} {'frame':>5s} fl {'n_band':>6s} {'n_y':>4s} {'n_vis':>5s} {'opaque':>6s} "
      f"{'sprite_lines':>12s} {'maxcode':>7s}")
    shown = per_frame
    if len(per_frame) > 60:
        shown = sorted(per_frame, key=lambda r: -r[4])[:12]
        P(f"(the 12 frames with the most covering sprites on one line, of {len(per_frame)})")
    for r in shown:
        P(f"{r[0]:22s} {r[1]:5d} {r[2]:2d} {r[3]:6d} {r[4]:4d} {r[5]:5d} {r[6]:6d} {r[7]:12d} {r[8]:7d}")
    P("")
    P("Over all captured frames and visible lines (per line: max / mean / 99th percentile):")
    for k, label in (("n_band", "non-hidden sprites in the band"), ("n_y", "sprites covering the line"),
                     ("n_vis", "... and x-visible"), ("opaque", "opaque pixels drawn")):
        v = A[k]
        P(f"  {label:34s} max {v.max():5d}  mean {v.mean():7.2f}  p99 {np.percentile(v, 99):7.1f}")
    mx = int(A["n_y"].max())
    nlines = len(A["n_y"])
    P("  lines with at least N covering sprites: " + ", ".join(
        f"N={n}: {int((A['n_y'] >= n).sum())} of {nlines}" for n in (32, 64, 96, 128, 192, 256)))
    P("")
    P("GFX ROM bytes a per-line engine reads (16 per sprite per covered line):")
    P(f"  worst line, y-covering sprites: {int(A['n_y'].max()) * 16} bytes; "
      f"x-visible only: {int(A['n_vis'].max()) * 16} bytes; mean {A['n_y'].mean() * 16:.1f} bytes/line")
    P("")
    P("Per-line budget: 448 pixel clocks x 8 = 3584 clk_sys cycles at 56 MHz.")
    P(f"  Worst line holds {mx} y-covering sprites = {mx * 16} pixel slots; at one pixel per clk_sys cycle"
      f" that is {mx * 16} of 3584 cycles ({100.0 * mx * 16 / 3584:.1f}%).")
    P(f"  Scanning the band's 256 entries costs 256 cycles at one entry per cycle, "
      f"{256 * 2} at two.")
    P(f"  Worst line by opaque pixels: {int(A['opaque'].max())}.")
    P("")
    cs = np.array(codes_all)
    top = sorted(parked_all.items(), key=lambda kv: -kv[1])[:4]
    P(f"Per band (strip): sprites with a visible pixel in the strip: max {act_max}; highest list index of one: {hi_max}")
    P("  entries with no visible pixel in their strip, most common (word0, x) : count: "
      + ", ".join(f"(0x{k[0]:04x}, {k[1]}) {v}" for k, v in top))
    P("")
    P(f"Codes: max {int(cs.max())} (0x{int(cs.max()):x}), {len(set(codes_all))} distinct over all frames; "
      f"codes >= {model.elements} (wrap by modulo in MAME): {int((cs >= model.elements).sum())}")
    P(f"  GFX bytes referenced: highest code {int(cs.max())} -> {(int(cs.max()) + 1) * 256} bytes "
      f"({(int(cs.max()) + 1) * 256 / 1048576:.2f} MB) of {len(model.gfx) / 1048576:.0f} MB")
    P("  per frame: sprites covering some line / distinct codes / largest multiplicity / sprites sharing a code:")
    tot = np.array(dup)
    P(f"    max {tot[:, 0].max()} / {tot[:, 1].max()} / {tot[:, 2].max()} / {tot[:, 3].max()};"
      f" mean {tot[:, 0].mean():.1f} / {tot[:, 1].mean():.1f} / {tot[:, 2].mean():.1f} / {tot[:, 3].mean():.1f}")
    P("")
    P(f"Sprite RAM past the 17 bands (words at byte offset >= 0x8800): non-zero words per frame "
      f"max {max(beyond)}, frames with any: {sum(1 for b in beyond if b)} of {len(beyond)}")
    P(f"Band 0 / band 16 non-zero words (draw_sprites reads bands 1..15 only): "
      f"max {max(u[0] for u in unused_bands)} / {max(u[1] for u in unused_bands)}")
    text = "\n".join(out) + "\n"
    print(text)
    if a.out:
        Path(a.out).write_text(text)
    return 0


def cmd_lines(a):
    d = Path(a.dir)
    model = Model(np.fromfile(find_gfx([d]), dtype=np.uint8))
    m = {x["frame"]: x for x in read_manifest(d)}[a.frame]
    spr, pal = load_frame(d, a.frame)
    r = model.render(spr, pal, m["flip"])
    ys = [a.line] if a.line is not None else sorted(r["lines"])
    for y in ys:
        L = r["lines"].get(y, [])
        print(f"line {y}: {len(L)} sprites: " + " ".join(f"{i}@b{b}({o})" for i, b, o, _ in L))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare")
    c.add_argument("dirs", nargs="+")
    c.add_argument("--write-ref")
    c.add_argument("--note", action="append", default=[], help="line copied into the --write-ref manifest")
    c.add_argument("--diff-dir")
    c.set_defaults(fn=cmd_compare)
    c = sub.add_parser("census")
    c.add_argument("dirs", nargs="+")
    c.add_argument("--out")
    c.set_defaults(fn=cmd_census)
    c = sub.add_parser("lines")
    c.add_argument("dir")
    c.add_argument("frame", type=int)
    c.add_argument("--line", type=int)
    c.set_defaults(fn=cmd_lines)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
