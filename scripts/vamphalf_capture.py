#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Video captures for the software model: sprite RAM, palette, flip state, MAME's screenshot.

    python scripts/vamphalf_capture.py misncrft [--gfx] [--frames 400,700,...] [--coin 1500]
                                       [--poke 3600:1,3700:0] [--out debug/vcap/misncrft]

One MAME run (scripts/mame/vcap.lua). Writes f<N>_spriteram.bin, f<N>_palette.bin, f<N>.png
and manifest.txt to --out, and with --gfx the whole "gfx" region as gfx.bin. The flip I/O
port comes from regions.json "video"; the set has no flip DIP, so --poke writes the port
through the IO space at the given frames (the driver's own flipscreen_w runs). See
scripts/render_model.py for the model compared against these, and docs/ROADMAP.md Phase 1a.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import (NO_WINDOW, check_lua_error, lua_env, lua_runner_env,  # noqa: E402
                          mame_cmd, mame_paths, regions)

DEFAULT_FRAMES = [400, 700, 1000, 1300, 1450, 2000, 2250, 2500, 2750, 3000, 3250, 3500, 3750, 4000]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frames", default=",".join(map(str, DEFAULT_FRAMES)))
    ap.add_argument("--coin", type=int, default=400, help="first coin frame (0 = no input)")
    ap.add_argument("--coinperiod", type=int, default=97, help="repeat the coin press (a single pulse is not credited)")
    ap.add_argument("--startperiod", type=int, default=211, help="repeat Start (continues)")
    ap.add_argument("--coinlen", type=int, default=5, help="frames coin and Start are held")
    ap.add_argument("--poke", default="", help="frame:hexvalue,... written to the flip port")
    ap.add_argument("--gfx", action="store_true")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    r = regions(a.set)
    out = Path(a.out) if a.out else REPO / "debug" / "vcap" / a.set
    out = out.resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    frames = [int(x) for x in a.frames.split(",")]
    inp = r.get("inputs", {})
    env = dict(os.environ, **lua_env(r), **lua_runner_env("vcap.lua"),
               CORE_OUT=out.as_posix(), VC_OUT=out.as_posix(),
               VC_FRAMES=",".join(map(str, frames)), VC_COIN=str(a.coin), VC_COINLEN=str(a.coinlen), VC_COINPERIOD=str(a.coinperiod),
               VC_STARTPERIOD=str(a.startperiod), VC_POKE=a.poke,
               VC_GFX=(out / "gfx.bin").as_posix() if a.gfx else "",
               VC_FLIPPORT=r["video"]["flip_port"],
               VC_IN_COIN=inp.get("coin", "Coin 1"), VC_IN_START=inp.get("start", "1 Player Start"),
               VC_IN_HOLD=inp.get("hold", "P1 Right"), VC_IN_PULSE=inp.get("pulse", "P1 Button 1"))
    cmd = mame_cmd(exe, a.set, "vcap.lua", mame_dir,
                   ["-nodrc", "-seconds_to_run", str(max(frames) // 60 + 30),
                    "-snapview", "native", "-snapshot_directory", (out / "snap").as_posix(),
                    "-nvram_directory", (out / "nvram").as_posix()])
    print(f"{a.set} frames {frames[0]}..{frames[-1]} -> {out}")
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    check_lua_error(out)
    if (out / "ERROR.txt").exists():
        sys.exit((out / "ERROR.txt").read_text())
    if "VCAP_OK" not in p.stdout + p.stderr:
        sys.exit("capture did not complete:\n" + "\n".join((p.stdout + p.stderr).splitlines()[-15:]))
    print((out / "manifest.txt").read_text().strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
