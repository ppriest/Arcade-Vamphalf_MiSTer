#!/usr/bin/env python3
"""Dump probe instance W (the first 256 writes to a local register slot) under the JTAG lock.

    python scripts/read_rfw.py 8 > board.txt

It resets the core through instance D's hold bit, so the log refills. Compare with sim/sys_tb
+rfslot=<slot>.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from coretools import core_root, quartus_stp   # noqa: E402
from hwlock import jtag_session                # noqa: E402
from identity import prefix                     # noqa: E402

REPO = core_root()
TCL = Path(__file__).resolve().parent / "read_rfw.tcl"

if __name__ == "__main__":
    with jtag_session("read_rfw"):
        r = subprocess.run([str(quartus_stp(REPO)), "-t", str(TCL), *sys.argv[1:]],
                           cwd=REPO, capture_output=True, text=True)
    print("# " + prefix(), file=sys.stderr)
    for ln in r.stdout.splitlines():
        if ln.startswith("RFW") or ln.startswith("NO "):
            print(ln)
    sys.exit(r.returncode)
