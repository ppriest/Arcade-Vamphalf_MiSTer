#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Standalone Quartus synthesis + fit + timing of one block (rtl/synth_check).

    python scripts/synth_check.py [--design e1|vh|qs] [--seed N] [--map-only] [--pipe]

--pipe: the e1 design with rtl/e1/e1_pipe.sv in place of e1_cpu.sv.

Works in debug/synth/synth_e1_<time> (a copy), refuses to run while a JTAG tool holds the
marker (hwlock). Prints ALMs, registers, block RAM and the worst setup slack
at the clock in e1_synth.sdc.
"""
import argparse, shutil, subprocess, sys, re, os
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import hwlock  # noqa: E402

QBIN = Path(os.environ.get("QUARTUS_BIN", "C:/intelFPGA_lite/17.0/quartus/bin64"))


def run(tool, args, cwd):
    exe = str(QBIN / (tool + ".exe"))
    r = subprocess.run([exe] + args, cwd=cwd, capture_output=True, text=True)
    (cwd / (tool + ".log")).write_text(r.stdout + r.stderr)
    if r.returncode:
        print(r.stdout[-3000:], r.stderr[-2000:])
        sys.exit(f"{tool} failed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--design", choices=["e1", "vh", "qs"], default="e1",
                    help="e1: the CPU, vh: the video block, qs: the sound board")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--map-only", action="store_true", help="stop after analysis and synthesis")
    ap.add_argument("--period", type=float, default=None, help="override clock period (ns)")
    ap.add_argument("--pipe", action="store_true", help="e1: the pipelined CPU, e1_pipe")
    a = ap.parse_args()
    hwlock.require_no_jtag("synth check")
    prefix = a.design
    import time
    sw = REPO / "debug" / "synth"             # debug/ is the large-file area (D:); build/ is the staged build's
    sw.mkdir(parents=True, exist_ok=True)
    for old in sw.glob("synth_e1*"):
        shutil.rmtree(old, ignore_errors=True)   # a shell sitting in one can keep it alive
    work = sw / f"synth_e1_{int(time.time())}"
    (sw / "synth_e1_latest.txt").write_text(str(work))
    shutil.copytree(REPO / "rtl", work / "rtl")
    # jt8052 reads its microcode by a path relative to the project directory (the repository root
    # in the full build)
    uc = work / "rtl/synth_check/rtl/qs1000/jt8051"
    uc.mkdir(parents=True)
    shutil.copy(REPO / "rtl/qs1000/jt8051/jt8051.uc", uc)
    if a.period:
        sdc = work / "rtl/synth_check/e1_synth.sdc"
        sdc.write_text(re.sub(r"-period [0-9.]+", f"-period {a.period}", sdc.read_text()))
    p = work / "rtl" / "synth_check"
    if a.pipe:
        for f, x, y in (("e1_synth.qsf", "../e1/e1_cpu.sv", "../e1/e1_pipe.sv"), ("e1_synth_top.sv", "e1_cpu cpu (", "e1_pipe cpu (.la_req(), .la_addr(), ")):
            s = (p / f).read_text()
            assert x in s
            (p / f).write_text(s.replace(x, y))
    with open(p / f"{prefix}_synth.qsf", "a") as q:
        q.write(f"set_global_assignment -name SEED {a.seed}\n")
    run("quartus_map", [f"{prefix}_synth", "-c", f"{prefix}_synth"], p)
    if a.map_only:
        print((p / f"{prefix}_synth.map.summary").read_text())
        return
    run("quartus_fit", [f"{prefix}_synth", "-c", f"{prefix}_synth"], p)
    run("quartus_sta", [f"{prefix}_synth", "-c", f"{prefix}_synth"], p)
    fit = (p / f"{prefix}_synth.fit.summary").read_text()
    print(fit)
    sta = (p / "quartus_sta.log").read_text()
    for m in re.finditer(r"Fmax Summary.*?(?=\n\n\n|\Z)", sta, re.S):
        print(m.group(0)[:600])
        break


main()
