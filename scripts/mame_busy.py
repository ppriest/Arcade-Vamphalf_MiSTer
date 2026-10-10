#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""How busy the main CPU is per frame in MAME (scripts/mame/busy.lua), as a distribution.

    python scripts/mame_busy.py aoh 28a09c b994,ba40 [--frames 3000] [--coin 600] [--fire 900]

The idle poll address and PCs are the driver's speedup handler's (init_<set>). Prints the busy fraction
percentiles and the overruns, and writes debug/busy/<set>.txt.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths   # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("addr", help="idle poll address, hex")
    ap.add_argument("pcs", help="comma-separated hex PCs of the poll")
    ap.add_argument("--frames", type=int, default=3000)
    ap.add_argument("--coin", type=int, default=600)
    ap.add_argument("--fire", type=int, default=900)
    a = ap.parse_args()
    out = REPO / "debug" / "busy"
    out.mkdir(parents=True, exist_ok=True)
    log = out / f"{a.set}.txt"
    mame_dir, exe = mame_paths()
    env = dict(os.environ, **lua_runner_env("busy.lua"), CORE_OUT=out.as_posix(), BUSY_OUT=log.as_posix(),
               BUSY_ADDR=a.addr, BUSY_PCS=a.pcs, BUSY_FRAMES=str(a.frames), BUSY_COIN=str(a.coin),
               BUSY_FIRE=str(a.fire))
    extra = ["-nvram_directory", str((out / "nvram").resolve()), "-cfg_directory", str((out / "cfg").resolve())]
    subprocess.run(mame_cmd(exe, a.set, "busy.lua", mame_dir, extra), cwd=str(mame_dir), env=env,
                   capture_output=True, text=True, timeout=7200, **NO_WINDOW)
    check_lua_error(out)
    vals, over = [], 0
    for line in log.read_text().splitlines():
        if line.startswith("#"):
            continue
        fr, _first, v, _reads = line.split()
        if int(fr) < 60:
            continue                      # boot
        if v == "overrun":
            over += 1
        else:
            vals.append(float(v))
    vals.sort()
    n = len(vals) + over
    pct = lambda q: vals[min(len(vals) - 1, int(q * len(vals)))] if vals else float("nan")
    print(f"{a.set}: {n} frames, busy fraction median {pct(0.5):.3f}, 90% {pct(0.9):.3f}, 99% {pct(0.99):.3f}, "
          f"max {vals[-1] if vals else float('nan'):.3f}; {over} overruns")


if __name__ == "__main__":
    main()
