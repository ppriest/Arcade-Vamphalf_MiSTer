#!/usr/bin/env python3
"""Log the board's frame time from probe S (Vamphalf_stp) while a game is played.

    python scripts/speed_log.py [--every 10] [--minutes 30] [--out debug/hw/speed.log]

Each interval: read instance S and clear it (scripts/read_issp.py S clear), then print the frames in
the interval, the frames that never reached the game's vblank wait (lost: the game's work for that
frame overran it, which is slowdown), the busiest frame's work as a share of its frame, and the last
frame's. The probe's idle range is the vblank wait of each game (Vamphalf.sv, instance S).
"""
import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def read_s():
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "read_issp.py"), "S", "clear"],
                       capture_output=True, text=True, cwd=str(REPO))
    f = {}
    for ln in r.stdout.splitlines():   # read_issp.py prefixes each line with "<core>|<build>|<set>|"
        m = re.match(r"^\s*(\w+)\s+(\d+)\s*$", ln.rsplit("|", 1)[-1])
        if m:
            f[m.group(1)] = int(m.group(2))
    return f, r.stdout + r.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--every", type=float, default=10)
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--out", default=str(REPO / "debug" / "hw" / "speed.log"))
    a = ap.parse_args()
    out = open(a.out, "a", buffering=1)
    end = time.time() + 60 * a.minutes
    tot_f = tot_l = 0
    worst = 0.0
    while time.time() < end:
        f, raw = read_s()
        if "frames" not in f:
            print("read failed:\n" + raw[-600:], flush=True)
            time.sleep(a.every)
            continue
        fc = f["frame_clocks"] or 1
        busiest = 100.0 * f["busiest"] / fc
        last = 100.0 * f["frame_busy"] / fc
        tot_f += f["frames"]
        tot_l += f["lost_frames"]
        worst = max(worst, busiest)
        line = (f"{time.strftime('%H:%M:%S')} frames {f['frames']:5d} lost {f['lost_frames']:4d} "
                f"busiest {busiest:5.1f}% last {last:5.1f}% (frame {fc} clocks) | total {tot_f} frames, "
                f"{tot_l} lost, worst {worst:.1f}%")
        print(line, flush=True)
        out.write(line + "\n")
        time.sleep(a.every)


if __name__ == "__main__":
    main()
