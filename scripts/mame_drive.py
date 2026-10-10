#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run a set with scheduled inputs and snapshots (scripts/mame/drive.lua), with any MAME build.

    python scripts/mame_drive.py royalpk2 --exe E:/mame-setadr/f32.exe --out debug/rp2/fix \\
        --frames 2400 --snaps 600,1200 --seq "900+6=Service 1;1000+6=Start/Deal/Draw" [--fresh]

Writes <out>/pc.txt (the PC once a frame), <out>/snap/<set>/*.png, and keeps the set's NVRAM and EEPROM
in <out>/nvram between runs (--fresh deletes it first). Prints the input field names with --fields.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths   # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--exe", help="the MAME executable (default: MAME_DIR/MAME_EXE)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--snaps", default="")
    ap.add_argument("--seq", default="")
    ap.add_argument("--fresh", action="store_true")
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    nv = out / "nvram"
    if a.fresh and nv.exists():
        shutil.rmtree(nv)
    (out / "lua_error.txt").unlink(missing_ok=True)
    mame_dir, exe = mame_paths()
    if a.exe:
        exe = Path(a.exe)
    env = dict(os.environ, **lua_runner_env("drive.lua"), CORE_OUT=out.as_posix(),
               DRV_LOG=(out / "pc.txt").as_posix(), DRV_FRAMES=str(a.frames), DRV_SNAPS=a.snaps, DRV_SEQ=a.seq)
    extra = ["-nvram_directory", str(nv), "-cfg_directory", str(out / "cfg"), "-snapshot_directory", str(out / "snap")]
    r = subprocess.run(mame_cmd(exe, a.set, "drive.lua", mame_dir, extra), cwd=str(mame_dir), env=env,
                       capture_output=True, text=True, timeout=7200, **NO_WINDOW)
    check_lua_error(out)
    if not (out / "pc.txt").exists():
        sys.exit(f"no output; MAME said:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    print(f"{a.set}: {sum(1 for _ in open(out / 'pc.txt'))} frames -> {out}")


if __name__ == "__main__":
    main()
