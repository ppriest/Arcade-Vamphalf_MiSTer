#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Limenko sprite census in MAME: the load the sprite frame buffer or a line renderer must carry.

    python scripts/lm_census.py <set> [<set> ...] [--skip 600] [--frames 1800]
    python scripts/lm_census.py <set> --coin 600 --skip 1500 --tag _play

Runs each set headless under scripts/mame/lm_census.lua. Raw rows: debug/lm_census/<set><tag>.txt
(row layout in the Lua header). Report per set: draw commands per frame and the lines they fall on;
CPU writes to the bank last drawn (zero means the drawn list is stable until the next command);
per command, the maximum and 99th percentile of the sprite count, sprites and pixels drawn, and
the per-line loads.
"""
import argparse
import os
import subprocess
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths, regions  # noqa: E402


def run(game, skip, frames, coin=0, tag=""):
    mame_dir, exe = mame_paths()
    r = regions(game)
    out = REPO / "debug" / "lm_census" / f"{game}{tag}.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    (out.parent / "lua_error.txt").unlink(missing_ok=True)
    inp = r.get("inputs", {})
    env = dict(os.environ, **lua_runner_env("lm_census.lua"),
               LC_OUT=out.as_posix(), CORE_OUT=out.parent.as_posix(),
               LC_SKIP=str(skip), LC_FRAMES=str(frames), LC_COIN=str(coin), LC_SNAP="1",
               LC_BITPOS=str(r.get("census", {}).get("bitpos", 31)),
               LC_IN_COIN=inp.get("coin", "Coin 1"), LC_IN_START=inp.get("start", "1 Player Start"),
               LC_IN_HOLD=inp.get("hold", ""), LC_IN_PULSE=inp.get("pulse", ""),
               LC_COIN_PERIOD=str(inp.get("coin_period", 0)), LC_START_PERIOD=str(inp.get("start_period", 0)),
               LC_PRESS=str(inp.get("press_len", 6)))
    cmd = mame_cmd(exe, game, "lm_census.lua", mame_dir,
                   ["-snapshot_directory", (out.parent / f"snap{tag}").as_posix(), "-snapview", "native"])
    subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, timeout=3600, **NO_WINDOW)
    check_lua_error(out.parent)
    return out


COLS = ["count", "enabled", "visible", "pix_all", "pix_vis", "maxline_vis", "maxline_full", "maxspr_line", "other"]


def pct(v, p):
    s = sorted(v)
    return s[min(len(s) - 1, int(len(s) * p))] if s else 0


def report(game, path):
    vtotal, cmds, frames = 0, [], []
    for line in path.read_text().splitlines():
        t = line.split()
        if t[0] == "vtotal":
            vtotal = int(t[1])
        elif t[0] == "C":
            cmds.append([int(x) for x in t[1:]])
        elif t[0] == "F":
            frames.append((int(t[1]), int(t[2]), int(t[3]), int(t[4]), [int(x, 16) for x in t[5:9]]))
    print(f"{game}: {len(frames)} frames, {len(cmds)} draw commands, {vtotal} lines a frame")
    per = Counter(f[1] for f in frames)
    print("  commands a frame: " + ", ".join(f"{k}: {per[k]}" for k in sorted(per)))
    lines = Counter(c[1] // 16 * 16 for c in cmds)
    print("  command line (16-line bins): " + ", ".join(f"{k}: {lines[k]}" for k in sorted(lines)))
    print(f"  CPU writes to the bank last drawn: {sum(f[2] for f in frames)} "
          f"in {sum(1 for f in frames if f[2])} frames; to the other bank: {sum(f[3] for f in frames)}")
    en = Counter()
    for f in frames:
        en[f[4][0] & 0xf] += 1
    print("  videoreg[0] bits 3:0 (spr bg md fg) at frame end: "
          + ", ".join(f"{k:04b}: {en[k]}" for k in sorted(en)))
    print(f"  {'per command':14s} {'max':>8s} {'p99':>8s} {'p50':>8s}")
    for i, name in enumerate(COLS):
        v = [c[2 + i] for c in cmds]
        print(f"  {name:14s} {max(v, default=0):8d} {pct(v, 0.99):8d} {pct(v, 0.5):8d}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    ap.add_argument("--report-only", action="store_true")
    a = ap.parse_args()
    for game in a.sets:
        path = REPO / "debug" / "lm_census" / f"{game}{a.tag}.txt"
        if not a.report_only:
            path = run(game, a.skip, a.frames, a.coin, a.tag)
        report(game, path)


if __name__ == "__main__":
    main()
