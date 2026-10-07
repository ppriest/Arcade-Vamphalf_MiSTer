#!/usr/bin/env python3
"""Dump the board's cache-miss log (probe instance T) under the JTAG lock.

    python scripts/read_misslog.py [count] > board.txt
    diff board.txt <(run_verilator.sh sys_tb ... +misslog=sim.txt)

The bench writes the same format with +misslog; the first differing line is where the board leaves
the simulated path.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from coretools import core_root, quartus_stp   # noqa: E402
from hwlock import jtag_session                # noqa: E402
from identity import prefix                     # noqa: E402

REPO = core_root()
TCL = Path(__file__).resolve().parent / "read_misslog.tcl"

if __name__ == "__main__":
    with jtag_session("read_misslog"):
        r = subprocess.run([str(quartus_stp(REPO)), "-t", str(TCL), *sys.argv[1:]],
                           cwd=REPO, capture_output=True, text=True)
    print("# " + prefix(), file=sys.stderr)
    for ln in r.stdout.splitlines():
        if ln[:3].strip().isdigit() or ln.startswith("logged") or ln.startswith("NO "):
            print(ln)
    sys.exit(r.returncode)
