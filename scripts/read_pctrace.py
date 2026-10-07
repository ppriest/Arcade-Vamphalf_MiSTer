#!/usr/bin/env python3
"""Dump probe instance P (PC and SR after 256 instructions from <start>) under the JTAG lock.

    python scripts/read_pctrace.py 1688 > board.txt

It resets the core through instance D's hold bit, so the window refills from the new start. Compare
with sim/sys_tb +pcfrom=<start>.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from coretools import core_root, quartus_stp   # noqa: E402
from hwlock import jtag_session                # noqa: E402
from identity import prefix                     # noqa: E402

REPO = core_root()
TCL = Path(__file__).resolve().parent / "read_pctrace.tcl"

if __name__ == "__main__":
    with jtag_session("read_pctrace"):
        r = subprocess.run([str(quartus_stp(REPO)), "-t", str(TCL), *sys.argv[1:]],
                           cwd=REPO, capture_output=True, text=True)
    print("# " + prefix(), file=sys.stderr)
    for ln in r.stdout.splitlines():
        if ln.startswith("PCT") or ln.startswith("NO "):
            print(ln)
    sys.exit(r.returncode)
