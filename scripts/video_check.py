#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the video RTL bench on captured frames and compare with the software model.

    python scripts/video_check.py <set> [--frames N ...] [--dirs debug/vcap/<set>_attract ...] [--flip]

For each frame: sim/video_tb (Verilator) renders it from the dump in the capture directory, the
software model (scripts/render_model.py, itself pixel-identical to MAME) renders the same dump,
and the two 320x236 images are compared. With no --frames, every frame of the manifest is used.
"""
import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import render_model as rm  # noqa: E402


def bench(d, fn, gfx, flip, out, lat):
    cmd = ["scripts/run_verilator.sh", "video_tb", f"+dir={d}", f"+frame={fn}", f"+gfx={gfx}",
           f"+out={out}", f"+flip={int(flip)}", f"+lat={lat}"]
    bash = "C:/Program Files/Git/bin/bash.exe"
    r = subprocess.run([bash] + cmd, cwd=REPO, capture_output=True, text=True)
    return r


def read_ppm(p):
    b = Path(p).read_bytes()
    parts = b.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    return np.frombuffer(parts[3], np.uint8).reshape(h, w, 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("--dirs", nargs="*")
    ap.add_argument("--frames", nargs="*", type=int)
    ap.add_argument("--lat", type=int, default=6)
    ap.add_argument("--max", type=int, default=0, help="limit the number of frames per directory")
    a = ap.parse_args()
    dirs = [Path(d) for d in (a.dirs or [REPO / "debug" / "vcap" / f"{a.set}_attract", REPO / "debug" / "vcap" / f"{a.set}_play"])]
    gfx = rm.find_gfx(dirs)
    model = rm.Model(np.fromfile(gfx, dtype=np.uint8))
    out = REPO / "debug" / "video_tb.ppm"
    tot = ok = 0
    for d in dirs:
        frames = rm.read_manifest(d)
        n = 0
        for m in frames:
            fn, flip = m["frame"], m["flip"]
            if a.frames and fn not in a.frames:
                continue
            if m["clipflip"] != flip:
                continue          # the first update after a flip change uses the old clip (MAME quirk, not modelled)
            if a.max and n >= a.max:
                break
            n += 1
            spr, pal = rm.load_frame(d, fn)
            exp = model.render(spr, pal, flip, clip_flip=flip, collect=False)["rgb"]
            r = bench(d.as_posix(), fn, Path(gfx).as_posix(), flip, out.as_posix(), a.lat)
            if r.returncode != 0:
                print(r.stdout[-600:], r.stderr[-600:])
                sys.exit("bench failed")
            got = read_ppm(out)
            bad = int((got != exp).any(axis=2).sum()) if got.shape == exp.shape else -1
            tot += 1
            ok += bad == 0
            print(f"{d.name:22s} frame {fn:5d} flip {flip} mismatch px {bad:6d} {'OK' if bad == 0 else 'DIFF'}  {r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ''}")
    print(f"{ok}/{tot} frames identical")
    sys.exit(0 if ok == tot else 1)


main()
