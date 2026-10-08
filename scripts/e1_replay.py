#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Replay the conformance traces e1_regress.py already made, without MAME: for RTL changes that keep
the ISA, where generating and tracing again would give the same traces.

    python scripts/e1_replay.py [name ...] [--out debug/e1] [--waits 0 3] [--jobs 8]

Runs the built bench (obj_verilator/e1_tb; build it with scripts/run_verilator.sh e1_tb) on
<out>/<name>/ref/ for each name (default: every directory with a ref/ trace) up to the end loop, as
e1_regress.py does, and prints one line per run. Exit status 1 if any run failed.
"""
import argparse
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from e1_regress import loop_index, parse_failures  # noqa: E402

BENCH = REPO / "obj_verilator" / "e1_tb" / "Vtb_e1.exe"


def run(d, w):
    info = (d / "info.txt").read_text().split("\n")[0]
    end = int(re.search(r"end ([0-9a-f]+)", info).group(1), 16)
    instr, bus = d / "ref" / "misncrft_instr.trace", d / "ref" / "misncrft_bus.trace"
    li = loop_index(instr, end)
    if li is None:
        return d.name, w, "NO-LOOP", ""
    r = subprocess.run([str(BENCH if BENCH.exists() else BENCH.with_suffix("")), "+instr=" + str(instr),
                        "+bus=" + str(bus), "+n=%d" % (li + 2), "+wait=%d" % w, "+cont=1"],
                       cwd=REPO, capture_output=True, text=True)
    txt = r.stdout + r.stderr
    m = re.search(r"(PASS|FAIL): (\d+) instructions, \d+ cycles \(([\d.]+) clk/instr\)", txt)
    fl = parse_failures(txt)
    detail = "instr=%s cpi=%s failing=%d" % (m.group(2), m.group(3), len(fl)) if m else txt[-600:]
    if fl:
        detail += "\n" + "\n".join("    %s idx %d pc %s %s" % (k, i, pc, dis) for k, i, pc, dis, _ in fl[:3])
    return d.name, w, m.group(1) if m else "ERROR", detail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--out", default="debug/e1")
    ap.add_argument("--waits", type=int, nargs="*", default=[0, 3])
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()
    out = REPO / a.out
    dirs = [out / n for n in a.names] if a.names else sorted(
        (p for p in out.iterdir() if (p / "ref" / "misncrft_instr.trace").exists() and (p / "info.txt").exists()),
        key=lambda p: (p.name[0], int(re.sub(r"\D", "", p.name) or 0)))
    jobs = [(d, w) for d in dirs for w in a.waits]
    with ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(lambda j: run(*j), jobs))
    bad = 0
    for name, w, st, detail in res:
        print("%-6s wait=%d  %-5s %s" % (name, w, st, detail))
        bad += st != "PASS"
    print("%d of %d runs failed" % (bad, len(res)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
