#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run sim/lm_video_tb on every captured frame and compare with the software model.

    python scripts/lm_video_check.py [<set> ...] [--tags ,_play] [--jobs 12] [--tiles-only]

Builds nothing: run scripts/run_verilator.sh lm_video_tb once first (it leaves obj_verilator/lm_video_tb/).
For each capture in debug/lmcap/<set><tag>/ the model (scripts/lm_render_model.py) renders the frame and the bench
renders it from the same RAM; prints per run the frames that are pixel-identical and the bench's line overruns.
"""
import argparse
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SETS = ["dynabomb", "sb2003", "legendoh", "hrthouse", "spotty"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--tags", default=",_play")
    ap.add_argument("--jobs", type=int, default=12)
    ap.add_argument("--tiles-only", action="store_true")
    a = ap.parse_args()
    work = REPO / "debug" / "lm" / "vtb"
    work.mkdir(parents=True, exist_ok=True)
    exe = work / "Vtb_lm_video.exe"
    shutil.copy(REPO / "obj_verilator" / "lm_video_tb" / "Vtb_lm_video.exe", exe)
    jobs = []
    for g in a.sets or SETS:
        for t in a.tags.split(","):
            cap = REPO / "debug" / "lmcap" / f"{g}{t}"
            mdir = work / f"model_{g}{t}"
            subprocess.run([sys.executable, str(REPO / "scripts" / "lm_render_model.py"), g, "--tag", t, "--out", str(mdir)]
                           + (["--tiles-only"] if a.tiles_only else []), check=True, capture_output=True)
            for ln in (cap / "manifest.txt").read_text().splitlines():
                if ln.strip():
                    jobs.append((g, t, int(ln.split()[0])))

    def run(j):
        g, t, n = j
        out = work / f"{g}{t}_f{n}.ppm"
        r = subprocess.run([str(exe), f"+img={REPO / 'debug' / 'lm' / (g + '.bin')}", f"+cap={REPO / 'debug' / 'lmcap' / (g + t)}",
                            f"+frame={n}", f"+out={out}", f"+set={g}"], capture_output=True, text=True)
        ov = r.stdout.strip().split("overruns ")[-1]
        x = np.asarray(Image.open(out).convert("RGB"))
        y = np.asarray(Image.open(work / f"model_{g}{t}" / f"f{n}.png").convert("RGB"))
        return g + t, n, int(np.any(x != y, axis=-1).sum()), ov

    res = {}
    with ThreadPoolExecutor(a.jobs) as ex:
        for name, n, d, ov in ex.map(run, jobs):
            res.setdefault(name, []).append((n, d, ov))
    for name, lst in res.items():
        bad = [(n, d) for n, d, ov in lst if d]
        print(f"{name:16s} {len(lst) - len(bad)} of {len(lst)} identical; overruns {sorted(set(o for _, _, o in lst))}"
              + (f"; differ (frame, pixels): {bad[:6]}" if bad else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
