#!/usr/bin/env python3
"""Compare sim/sys_tb frames with MAME's screenshots.

    python scripts/sys_compare.py <rtl dir> <mame dir> [--offset N] [--search A:B]

<rtl dir> holds f<N>.ppm from sim/sys_tb (+snap); <mame dir> holds f<M>.png or <set>_*_f<M>.png from
scripts/vamphalf_capture.py. With --offset, RTL frame N is compared with MAME frame N - offset (the RTL
boots slower than MAME's E1, then runs frame for frame). With --search, each RTL frame is matched
against every MAME frame in the directory whose number lies in [N-B, N-A], and the best is printed.
"""
import argparse
import glob
import os
import re

import numpy as np
from PIL import Image


def frames(d, ext):
    out = {}
    for f in glob.glob(os.path.join(d, "*." + ext)):
        m = re.search(r"f(\d+)\." + ext + "$", os.path.basename(f))
        if m:
            out[int(m.group(1))] = f
    return out


def load(f):
    return np.asarray(Image.open(f).convert("RGB"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rtl")
    ap.add_argument("mame")
    ap.add_argument("--offset", type=int)
    ap.add_argument("--search")
    a = ap.parse_args()
    rtl, mame = frames(a.rtl, "ppm"), frames(a.mame, "png")
    same = total = 0
    for n in sorted(rtl):
        r = load(rtl[n])
        if a.offset is not None:
            m = mame.get(n - a.offset)
            if m is None:
                continue
            d = int(np.any(r != load(m), axis=2).sum())
            total += 1
            same += d == 0
            print(f"RTL f{n} vs MAME f{n - a.offset}: {d} pixels differ")
        else:
            lo, hi = (int(x) for x in a.search.split(":"))
            best = sorted((int(np.any(r != load(f), axis=2).sum()), k)
                          for k, f in mame.items() if n - hi <= k <= n - lo)
            print(f"RTL f{n}: best {best[:3]}")
    if total:
        print(f"{same}/{total} frames identical")


if __name__ == "__main__":
    main()
