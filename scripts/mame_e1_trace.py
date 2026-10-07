#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Per-instruction and bus-access trace of the Hyperstone main CPU from reset, from MAME.

    python scripts/mame_e1_trace.py misncrft 200000 [--out sim/ref/misncrft] [--rompath DIR]

Runs MAME with -debug -nodrc (interpreter + debugger instruction hook) under
scripts/mame/e1trace.lua, then converts the raw log to the format in
docs/E1_TRACE_FORMAT.md: <set>_instr.trace (one line per instruction, register
deltas) and <set>_bus.trace (bus accesses tagged with the instruction index).
NVRAM starts empty in a scratch directory, as in mame_boot_trace.py.
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
from e1trace_convert import convert  # noqa: E402


def run(game, n, raw_dir, frames, timeout, lean=False, rompath=None):
    mame_dir, exe = mame_paths()
    if raw_dir.exists():
        shutil.rmtree(raw_dir)
    raw_dir.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_env(regions(game)), **lua_runner_env("e1trace.lua"),
                   CORE_OUT=raw_dir.as_posix(), CORE_TAG=game,
                   CORE_TRACE_N=str(n), CORE_FRAMES=str(frames),
                   CORE_LEAN="1" if lean else "0")
        cmd = mame_cmd(exe, game, "e1trace.lua", mame_dir,
                       ["-nvram_directory", nv, "-nodrc", "-seconds_to_run", "3600"])
        cmd[cmd.index("-nodebug")] = "-debug"
        if rompath:
            # searched before the usual paths: a directory holding a modified <game>.zip
            i = cmd.index("-rompath") + 1
            cmd[i] = ";".join([str(Path(rompath).resolve())] + [cmd[i]])
        return subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True,
                              timeout=timeout, **NO_WINDOW)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("n", type=int, help="instructions to keep")
    ap.add_argument("--out", default=None)
    ap.add_argument("--frames", type=int, default=100000, help="backstop frame count")
    ap.add_argument("--timeout", type=int, default=7200)
    ap.add_argument("--lean", action="store_true",
                    help="PC-only trace to --frames, writes <set>_frames.txt (instructions per frame)")
    ap.add_argument("--keep-raw", action="store_true")
    ap.add_argument("--rompath", default=None,
                    help="directory searched first for ROM sets (e.g. a modified <set>.zip)")
    a = ap.parse_args()
    out = Path(a.out) if a.out else REPO / "sim" / "ref" / a.game
    out.mkdir(parents=True, exist_ok=True)
    raw = REPO / "debug" / f"{a.game}-e1raw{'-lean' if a.lean else ''}"
    regs = regions(a.game)
    r = run(a.game, a.n, raw, a.frames, a.timeout, a.lean, a.rompath)
    check_lua_error(raw)
    if not (raw / f"{a.game}_e1.done").exists():
        sys.stdout.write(r.stdout[-2000:])
        sys.stderr.write(r.stderr[-2000:])
        sys.exit("no completion marker; see MAME output above")
    if a.lean:
        counts, cur = [], 0
        with open(raw / f"{a.game}_e1.raw", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("I "):
                    cur += 1
                elif line.startswith("# frame"):
                    counts.append(cur)
                    cur = 0
        (out / f"{a.game}_frames.txt").write_text(
            "# instructions executed in each frame (frame 0 first), interpreter, -nodrc\n"
            + "".join(f"{i} {c}\n" for i, c in enumerate(counts)), encoding="utf-8")
        print(f"{len(counts)} frames; first {counts[:5]} ...")
    else:
        convert(raw / f"{a.game}_e1.raw", out, a.game, a.n, regs["bus_bytes"])
    if not a.keep_raw:
        shutil.rmtree(raw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
