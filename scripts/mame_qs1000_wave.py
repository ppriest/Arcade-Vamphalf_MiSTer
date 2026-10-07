#!/usr/bin/env python3
"""Capture the QS1000's wavetable register writes and MAME's audio, for the voice-engine model.

    python scripts/mame_qs1000_wave.py misncrft [--frames 3600] [--coin 0] [--out D:/.../qs1000wave]

Writes <out>/<set>_wave.txt (scripts/mame/qs1000wave.lua: every write to 0x200-0x211 with its
750 kHz tick) and <out>/<set>.wav (MAME's -wavwrite of the same run, for listening and for the
model's level check). The writes replayed into scripts/qs1000_model.py give MAME's engine output
sample for sample; the RTL bench compares against that.
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
    ap.add_argument("--frames", type=int, default=3600)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--fire", type=int, default=0, help="hold P1 button 1 from this frame")
    ap.add_argument("--latch", default="", help="log the sound latch writes at this I/O address (hex)")
    ap.add_argument("--out", default=str(REPO / "debug" / "qs1000wave"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "lua_error.txt").unlink(missing_ok=True)
    mame_dir, exe = mame_paths()
    env = dict(os.environ, **lua_runner_env("qs1000wave.lua"), CORE_OUT=out.as_posix(),
               QW_OUT=(out / f"{a.set}_wave.txt").as_posix(), QW_FRAMES=str(a.frames), QW_COIN=str(a.coin),
               QW_FIRE=str(a.fire), QW_LATCH=a.latch)
    cmd = mame_cmd(exe, a.set, "qs1000wave.lua", mame_dir,
                   ["-wavwrite", (out / f"{a.set}.wav").as_posix(), "-samplerate", "48000"])
    r = subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, text=True, timeout=7200, **NO_WINDOW)
    check_lua_error(out)
    w = out / f"{a.set}_wave.txt"
    if not w.exists():
        sys.exit(f"no output; MAME said:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    n = sum(1 for ln in w.open() if ln.startswith("W "))
    print(f"{w}: {n} writes; {out / (a.set + '.wav')}")


if __name__ == "__main__":
    main()
