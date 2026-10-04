#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""When each game writes video RAM and registers, relative to vblank, in MAME.

    python scripts/write_timing.py <set> [<set> ...] [--skip 600] [--frames 1800]
    python scripts/write_timing.py <set> --coin 600 --skip 1500 --tag _play
    python scripts/write_timing.py <set> --extra tbank:400000:400007

Runs each set headless (scripts/mame/wtiming.lua) and counts writes to the
regions named in regions.json "sweep" (plus --extra), by scanline, over --frames
frames after --skip. Raw results: debug/wtiming/<set><tag>.txt. Report per region:
writes per frame; the share in the first 2 lines after vblank start, in vblank,
and in the first 24 lines; and a strip of 8-line buckets from vblank start
(' ' none, '.' under 1%, 0-9 tenths, '#' over 90%).

Decides where sprite/tile snapshots and register latches go: see the skill's
references/video_write_sweep.md. Run attract and play (--coin): play differs.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import (NO_WINDOW, lua_env, lua_runner_env, mame_cmd,  # noqa: E402
                          mame_paths, regions, spec)


def run(game, skip, frames, coin=0, tag="", extra=""):
    mame_dir, exe = mame_paths()
    r = regions()
    out = REPO / "debug" / "wtiming" / f"{game}{tag}.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    table = {**r.get("read", {}), **r.get("wtap", {})}
    taps = spec(table, r.get("sweep"))
    if extra:
        taps = f"{taps},{extra}" if taps else extra
    inp = r.get("inputs", {})
    env = dict(os.environ, **lua_env(r), **lua_runner_env("wtiming.lua"),
               WT_OUT=out.as_posix(), WT_TAPS=taps,
               WT_SKIP=str(skip), WT_FRAMES=str(frames), WT_COIN=str(coin), WT_SNAP="1",
               WT_IN_COIN=inp.get("coin", "Coin 1"), WT_IN_START=inp.get("start", "1 Player Start"),
               WT_IN_HOLD=inp.get("hold", "P1 Right"), WT_IN_PULSE=inp.get("pulse", "P1 Button 1"))
    cmd = mame_cmd(exe, game, "wtiming.lua", mame_dir,
                   ["-snapshot_directory", (out.parent / f"snap{tag}").as_posix(),
                    "-snapview", "native"])
    subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, timeout=3600, **NO_WINDOW)
    return out


def parse(path):
    d = {"hist": {}, "last": {}}
    for line in path.read_text().splitlines():
        k, _, v = line.partition(" ")
        if k in ("vtotal", "vbstart", "frames"):
            d[k] = int(v)
        else:
            name, _, vals = v.partition(" ")
            d[k][name] = [int(x) for x in vals.split(",")]
    return d


def report(game, d):
    vt, vb, nf = d["vtotal"], d["vbstart"], d["frames"]
    blank = (vt - vb) % vt
    print(f"{game}: {vt} lines, vblank start {vb} ({blank} lines of vblank), {nf} frames")
    print(f"  {'region':10s} {'/frame':>7s} {'+0..1':>6s} {'vblank':>6s} {'+0..23':>6s}  "
          f"from vblank start, 8 lines a column")
    for name, h in d["hist"].items():
        total = sum(h)
        if not total:
            continue
        rel = [h[(i + vb) % vt] for i in range(vt)]
        strip = ""
        for b in range(0, vt, 8):
            f = sum(rel[b:b + 8]) / total
            strip += " " if f == 0 else "." if f < 0.01 else "#" if f > 0.9 else str(min(9, int(f * 10)))
        pct = lambda n: 100.0 * sum(rel[:n]) / total  # noqa: E731
        print(f"  {name:10s} {total / nf:7.1f} {pct(2):5.1f}% {pct(blank):5.1f}% {pct(24):5.1f}%  "
              f"|{strip}|")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--coin", type=int, default=0,
                    help="insert a coin at this frame and play; counting still starts at --skip")
    ap.add_argument("--extra", default="", help="more taps, name:hexlo:hexhi[,...]")
    ap.add_argument("--tag", default="", help="suffix for the result file")
    ap.add_argument("--reuse", action="store_true", help="report existing results only")
    a = ap.parse_args()
    for g in a.sets:
        path = REPO / "debug" / "wtiming" / f"{g}{a.tag}.txt"
        if not a.reuse or not path.exists():
            run(g, a.skip, a.frames, a.coin, a.tag, a.extra)
        if not path.exists():
            print(f"{g}: no result (MAME failed?)\n")
            continue
        report(f"{g}{a.tag}" + (f" (coin at frame {a.coin})" if a.coin else ""), parse(path))


if __name__ == "__main__":
    sys.exit(main())
