#!/usr/bin/env python3
"""Capture the main CPU's I/O accesses in MAME, to compare the FPGA protection with the core.

    python scripts/mame_prot_trace.py misncrft [--frames 1200] [--out debug/prot]

Writes <out>/<set>_io.txt (scripts/mame/prottrace.lua: "<frame> W|R <address> <data>" for every I/O
access). sim/sys_tb +prot=<file> writes the core's protection accesses in the same form.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("--frames", type=int, default=1200)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--fire", type=int, default=0)
    ap.add_argument("--out", default=str(REPO / "debug" / "prot"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "lua_error.txt").unlink(missing_ok=True)
    mame_dir, exe = mame_paths()
    dst = out / f"{a.set}_io.txt"
    env = dict(os.environ, **lua_runner_env("prottrace.lua"), CORE_OUT=out.as_posix(),
               PT_OUT=dst.resolve().as_posix(), PT_FRAMES=str(a.frames),
               PT_COIN=str(a.coin), PT_FIRE=str(a.fire))
    cmd = mame_cmd(exe, a.set, "prottrace.lua", mame_dir)
    r = subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, text=True, timeout=7200, **NO_WINDOW)
    check_lua_error(out)
    if not dst.exists():
        sys.exit(f"no output; MAME said:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    n = sum(1 for ln in dst.open() if not ln.startswith("#"))
    print(f"{dst}: {n} accesses")


if __name__ == "__main__":
    main()
