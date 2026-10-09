#!/usr/bin/env python3
"""How busy the core's CPU is per frame in each game, on the whole-board bench.

    python scripts/speed_survey.py [set ...] [--frames 1300] [--jobs 8]

Each set runs on sim/sys_tb with a coin at frame 300 (and every 300 after, Start 30 frames later) and P1
button 1 tapped from frame 600, its idle loop taken from MAME's speed-up handler for the set (IDLE, the PC
in vamphalf.cpp's init_<set> speedup_16_r / speedup_32_r): a window of 0x20 bytes either side. A frame's
busy share is the clocks the CPU spent outside that window; a frame that never entered it is "without idle",
which on the board is a slowdown frame. Writes debug/speed/<set>.txt and prints a table.
"""
import argparse
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# set: (family, E1-32, idle-loop PC from MAME's speed-up handler)
IDLE = {
    "misncrft": (0, 0, 0xff5a),   "wivernwg": (1, 1, 0x10766),  "vamphalf": (2, 0, 0x82ec),
    "coolmini": (3, 0, 0x75f88),  "dquizgo2": (3, 0, 0xaa630),  "toyland":  (3, 0, 0x130c2),
    "mrkicker": (4, 0, 0x41ec6),  "mrkickera": (10, 1, 0x46a30),  "boonggab": (12, 0, 0x131a6),  "dtfamily": (4, 0, 0x12fa6),  "jmpbreak": (5, 0, 0x984a),
    "poosho":   (5, 0, 0xa8c78),  "newxpang": (6, 0, 0x8b8e),   "mrdig":    (6, 0, 0xae38),
    "suplup":   (7, 0, 0xaf184),  "worldadv": (9, 0, 0x93ae),
}


def run(s, frames):
    fam, b32, pc = IDLE[s]
    out = REPO / "debug" / "speed" / f"{s}.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [str(REPO / "obj_verilator/sys_tb/Vtb_sys"), f"+img={REPO / 'debug/sys' / (s + '.bin')}", f"+board={b32}",
           f"+family={fam}", f"+frames={frames}", "+coin=300", "+coinrep=1", "+fire=600",
           f"+idle={pc - 0x20:x}:{pc + 0x20:x}"]
    with open(out, "w") as f:
        subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=str(REPO))
    t = out.read_text(errors="replace")
    busiest = [int(x) for x in re.findall(r"busiest (\d+)%", t)]
    lost = sum(int(x) for x in re.findall(r"frames without idle (\d+)", t))
    m = re.search(r"idle loop: busiest frame ([\d.]+)% busy, (\d+) frames", t)
    return s, (float(m.group(1)) if m else None), (int(m.group(2)) if m else lost), busiest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--frames", type=int, default=1300)
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()
    sets = a.sets or list(IDLE)
    with ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(lambda s: run(s, a.frames), sets))
    print(f"{'set':10s} {'busiest frame':>14s} {'frames without idle (after 100)':>32s}   busiest per 60 frames")
    for s, b, lost, per in res:
        print(f"{s:10s} {('%.1f%%' % b) if b is not None else '-':>14s} {lost:>32d}   {' '.join(map(str, per[-12:]))}")


if __name__ == "__main__":
    main()
