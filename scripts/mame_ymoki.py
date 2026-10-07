#!/usr/bin/env python3
"""Capture a YM2151 + M6295 board's sound writes and MAME's audio, for sim/ymoki_tb.

    python scripts/mame_ymoki.py vamphalf [--frames 1800] [--coin 0] [--out debug/ymoki]

Writes <out>/<set>_ymoki.txt (scripts/mame/ymoki.lua) and <out>/<set>.wav (MAME's -wavwrite of the same run).
The ports come from PORTS, the set's I/O map in vamphalf.cpp.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths  # noqa: E402

# set -> (YM2151 address port, M6295 port), from the set's I/O map
PORTS = {
    "vamphalf": (0x050, 0x030),     # vamphalf_io
    "coolmini": (0x150, 0x130),     # coolmini_io (also mrkicker_io)
    "dquizgo2": (0x150, 0x130),
    "toyland":  (0x150, 0x130),
    "mrkicker": (0x150, 0x130),
    "dtfamily": (0x150, 0x130),
    "jmpbreak": (0x1a0, 0x110),     # jmpbreak_io
    "poosho":   (0x1a0, 0x110),
    "newxpang": (0x030, 0x020),     # mrdig_io
    "mrdig":    (0x030, 0x020),
    "suplup":   (0x030, 0x020),     # suplup_io
    "solitaire": (0x160, 0x050),    # solitaire_io
    "worldadv": (0x1c0, 0x190),     # worldadv_io
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--out", default=str(REPO / "debug" / "ymoki"))
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / "lua_error.txt").unlink(missing_ok=True)
    ym, oki = PORTS[a.set]
    mame_dir, exe = mame_paths()
    dst = out / f"{a.set}_ymoki.txt"
    env = dict(os.environ, **lua_runner_env("ymoki.lua"), CORE_OUT=out.as_posix(), YO_OUT=dst.as_posix(),
               YO_FRAMES=str(a.frames), YO_YM=f"{ym:x}", YO_OKI=f"{oki:x}", YO_COIN=str(a.coin))
    cmd = mame_cmd(exe, a.set, "ymoki.lua", mame_dir,
                   ["-wavwrite", (out / f"{a.set}.wav").as_posix(), "-samplerate", "48000"])
    r = subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, text=True, timeout=7200, **NO_WINDOW)
    check_lua_error(out)
    if not dst.exists():
        sys.exit(f"no output; MAME said:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    lines = [ln for ln in dst.open() if not ln.startswith("#")]
    print(f"{dst}: {sum(1 for l in lines if l[0] == 'Y')} YM2151 writes, {sum(1 for l in lines if l[0] == 'O')} "
          f"M6295 writes; {out / (a.set + '.wav')}")


if __name__ == "__main__":
    main()
