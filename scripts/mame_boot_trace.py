#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture the first N main-CPU bus accesses of a boot from MAME.

    python scripts/mame_boot_trace.py <set> 20000
    -> debug/<set>-boot/<set>_boot.trace

The reference the RTL CPU's boot is diffed against (scripts/compare_boot_trace.py).
CPU, bus width and address range come from scripts/mame/regions.json.

  * -autoboot_delay 0: a trace that starts late has missed the reset vector fetch.
  * The output directory is recreated, so a trace is never a mixture of two runs.
  * NVRAM starts empty in a scratch directory unless debug/<set>-nvram/<set>/ holds a
    pinned image: MAME writes NVRAM back on exit, so reusing its own directory
    changes the reference for the next run.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import (NO_WINDOW, check_lua_error, lua_env, lua_runner_env,  # noqa: E402
                          mame_cmd, mame_paths, regions)


def trace_env(r):
    t = r.get("trace", {})
    ipl = t.get("ipl") or {}
    io, vec = t.get("io", []), t.get("vectors", ["0x0", "0x0"])
    if io and isinstance(io[0], str):     # one [lo, hi] pair, or a list of them
        io = [io]
    h = lambda v: f"{int(v, 16):x}"  # noqa: E731
    return {**lua_env(r), "CORE_ADDR_HI": h(t.get("addr_hi", "0xffffff")),
            "CORE_IO": ",".join(f"{h(lo)}:{h(hi)}" for lo, hi in io),
            "CORE_VEC_LO": h(vec[0]), "CORE_VEC_HI": h(vec[1]),
            "CORE_IPL_REG": ipl.get("reg", ""), "CORE_IPL_SHIFT": str(ipl.get("shift", 0)),
            "CORE_IPL_MASK": str(ipl.get("mask", 0))}


def run_traced(game, lua, out, env_extra, seconds):
    """Run MAME with a pinned or empty NVRAM directory; return the CompletedProcess."""
    mame_dir, exe = mame_paths()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    pinned = REPO / "debug" / f"{game}-nvram" / game
    with tempfile.TemporaryDirectory() as nv:
        if pinned.is_dir():
            shutil.copytree(pinned, Path(nv) / game)
        env = dict(os.environ, **trace_env(regions()), **lua_runner_env(lua),
                   CORE_OUT=out.as_posix(), CORE_TAG=game, **env_extra)
        cmd = mame_cmd(exe, game, lua, mame_dir,
                       ["-nvram_directory", nv, "-seconds_to_run", str(seconds)])
        return subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True,
                              **NO_WINDOW)


def check(trace, r):
    check_lua_error(trace.parent)
    if not trace.exists():
        sys.stdout.write(r.stdout[-2000:])
        sys.stderr.write(r.stderr[-2000:])
        sys.exit("no trace written; see MAME output above")
    lines = trace.read_text().splitlines()
    print("\n".join(lines[-2:]))
    if any(ln.startswith("# FIRST ERROR") for ln in lines):
        sys.exit("the trace recorded a tap error; see the file")
    print(f"-> {trace}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("n", type=int, help="accesses to log")
    ap.add_argument("--seconds", type=int, default=30, help="MAME -seconds_to_run backstop")
    a = ap.parse_args()
    out = REPO / "debug" / f"{a.game}-boot"
    r = run_traced(a.game, "boottrace.lua", out, {"CORE_TRACE_N": str(a.n)}, a.seconds)
    check(out / f"{a.game}_boot.trace", r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
