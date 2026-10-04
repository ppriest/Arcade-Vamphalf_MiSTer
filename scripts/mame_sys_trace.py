#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The main CPU's writes, I/O reads and interrupts for the first N frames, from MAME.

    python scripts/mame_sys_trace.py <set> 120
    -> debug/<set>-sys/<set>_sys.trace

The reference the RTL main board is compared with. I/O range, vector table and
interrupt-mask field come from regions.json "trace"; see scripts/mame/systrace.lua.
NVRAM handling as in mame_boot_trace.py: pin an image in debug/<set>-nvram/<set>/
when the game's behaviour from reset depends on it, and load the same file in the
RTL bench.
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_boot_trace import check, run_traced  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("frames", type=int)
    ap.add_argument("--seconds", type=int, default=120)
    a = ap.parse_args()
    out = REPO / "debug" / f"{a.game}-sys"
    r = run_traced(a.game, "systrace.lua", out, {"CORE_FRAMES": str(a.frames)}, a.seconds)
    check(out / f"{a.game}_sys.trace", r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
