#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Limenko video captures from MAME for the software model and the video bench.

    python scripts/lm_capture.py <set> [--frames 600,900,...] [--coin 600] [--tag _play]
    -> debug/lmcap/<set><tag>/f<N>_{fg,md,bg,pal,vreg,spr}.bin, f<N>.png, manifest.txt

scripts/mame/lm_vcap.lua describes the files. --coin inserts coins from that frame (every 97 frames) and plays
as scripts/mame/wtiming.lua does.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths, regions  # noqa: E402

DEFAULT_FRAMES = list(range(600, 3601, 150))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frames", default=",".join(map(str, DEFAULT_FRAMES)))
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    mame_dir, exe = mame_paths()
    r = regions(a.set)
    out = (REPO / "debug" / "lmcap" / f"{a.set}{a.tag}").resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    frames = [int(x) for x in a.frames.split(",")]
    inp = r.get("inputs", {})
    env = dict(os.environ, **lua_runner_env("lm_vcap.lua"), CORE_OUT=out.as_posix(), LV_OUT=out.as_posix(),
               LV_FRAMES=",".join(map(str, frames)), LV_COIN=str(a.coin),
               LV_BITPOS=str(r.get("census", {}).get("bitpos", 31)),
               LV_IN_COIN=inp.get("coin", "Coin 1"), LV_IN_START=inp.get("start", "1 Player Start"),
               LV_IN_HOLD=inp.get("hold", ""), LV_IN_PULSE=inp.get("pulse", ""))
    cmd = mame_cmd(exe, a.set, "lm_vcap.lua", mame_dir,
                   ["-seconds_to_run", str(max(frames) // 60 + 30), "-snapview", "native",
                    "-snapshot_directory", (out / "snap").as_posix(), "-nvram_directory", (out / "nvram").as_posix()])
    print(f"{a.set} frames {frames[0]}..{frames[-1]} -> {out}")
    subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    check_lua_error(out)
    if (out / "ERROR.txt").exists():
        sys.exit((out / "ERROR.txt").read_text())
    got = (out / "manifest.txt").read_text().split("\n")
    print(f"{sum(1 for x in got if x.strip())} frames captured")
    return 0


if __name__ == "__main__":
    sys.exit(main())
