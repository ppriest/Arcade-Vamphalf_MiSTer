#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Per-instruction and bus-access trace of the QS1000's 8052 from reset, from MAME.

    python scripts/mame_qs1000_trace.py misncrft 500000 [--out debug/qs1000]

Runs MAME with -debug under scripts/mame/qs1000trace.lua, then converts the raw log to the
format in docs/QS1000_TRACE_FORMAT.md: <set>_instr.trace and <set>_bus.trace.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths  # noqa: E402

LATCH = {"misncrft": 0x100, "misncrfta": 0x100, "wivernwg": 0x1500, "wyvernwg": 0x1500,
         "wyvernwga": 0x1500}


def run(game, n, raw_dir, frames, timeout):
    mame_dir, exe = mame_paths()
    if raw_dir.exists():
        shutil.rmtree(raw_dir)
    raw_dir.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_runner_env("qs1000trace.lua"),
                   CORE_OUT=raw_dir.as_posix(), CORE_TAG=game, CORE_TRACE_N=str(n),
                   CORE_FRAMES=str(frames), CORE_LATCH=hex(LATCH[game]))
        cmd = mame_cmd(exe, game, "qs1000trace.lua", mame_dir,
                       ["-nvram_directory", nv, "-seconds_to_run", "3600"])
        cmd[cmd.index("-nodebug")] = "-debug"
        return subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True,
                              timeout=timeout, **NO_WINDOW)


LEN3 = {0x02, 0x10, 0x12, 0x20, 0x30, 0x43, 0x53, 0x63, 0x75, 0x85, 0x90, 0xB4, 0xB5, 0xB6,
        0xB7, *range(0xB8, 0xC0), 0xD5}
LEN2 = {0x05, 0x15, 0x24, 0x25, 0x34, 0x35, 0x40, 0x42, 0x44, 0x45, 0x50, 0x52, 0x54, 0x55,
        0x60, 0x62, 0x64, 0x65, 0x70, 0x72, 0x74, 0x76, 0x77, *range(0x78, 0x80), 0x80, 0x82,
        0x86, 0x87, *range(0x88, 0x90), 0x92, 0x94, 0x95, 0xA0, 0xA2, 0xA6, 0xA7,
        *range(0xA8, 0xB0), 0xB0, 0xB2, 0xC0, 0xC2, 0xC5, 0xD0, 0xD2, *range(0xD8, 0xE0),
        0xE5, 0xF5}


def oplen(op):
    if op & 0x0F == 1:
        return 2
    return 3 if op in LEN3 else 2 if op in LEN2 else 1


def convert(raw, outdir, game, n):
    outdir.mkdir(parents=True, exist_ok=True)
    fi = open(outdir / f"{game}_instr.trace", "w", encoding="utf-8", newline="\n")
    fb = open(outdir / f"{game}_bus.trace", "w", encoding="utf-8", newline="\n")
    fi.write("# QS1000 8052 instruction trace, MAME, state BEFORE each instruction.\n")
    fi.write("# format: docs/QS1000_TRACE_FORMAT.md\n")
    fi.write("# idx pc a psw sp dptr r0..r7 b ie ip tcon tmod tl0 th0 tl1 th1 | disasm\n")
    fb.write("# QS1000 bus trace; idx = instruction executing (L: the one whose record precedes the write).\n")
    fb.write("# idx space kind addr data\n")
    idx = -1
    stats = {}
    pc = nfetch = got = 0
    with open(raw, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("I "):
                idx += 1
                if idx >= n:
                    break
                parts = line[2:].split(" ", 22)
                pc, nfetch = int(parts[0], 16), -1
                regs, dis = parts[:22], parts[22] if len(parts) > 22 else ""
                fi.write(f"{idx} " + " ".join(r.lower() for r in regs) + " | " + dis + "\n")
            elif line.startswith("B "):
                _, sp, k, a, d = line.split()
                if sp == "P" and k == "R":
                    # the instruction's own fetch is pc, pc+1, ...; later rows are MOVC reads
                    if nfetch < 0:
                        nfetch, got = oplen(int(d, 16)), 0
                    if got < nfetch:
                        # the opcode row of the first instruction after an interrupt entry
                        # reports address 0000; the data byte is the opcode at pc
                        if got and int(a, 16) != pc + got:
                            sys.exit(f"fetch order at instruction {idx}: {a} after pc {pc:04x}")
                        got += 1
                        continue
                fb.write(f"{max(idx, 0)} {sp} {k} {a.lower()} {d.lower()}\n")
                stats[(sp, k)] = stats.get((sp, k), 0) + 1
            elif line.startswith("L "):
                _, d, off = line.split()[:3]
                fb.write(f"{max(idx, 0)} L W {off.lower()} {d.lower()}\n")
                stats[("L", "W")] = stats.get(("L", "W"), 0) + 1
    fi.close()
    fb.close()
    return min(idx + 1, n), stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game", choices=sorted(LATCH))
    ap.add_argument("n", type=int, help="instructions to keep")
    ap.add_argument("--out", default=None)
    ap.add_argument("--frames", type=int, default=100000, help="backstop frame count")
    ap.add_argument("--timeout", type=int, default=7200)
    ap.add_argument("--keep-raw", action="store_true")
    a = ap.parse_args()
    out = Path(a.out) if a.out else REPO / "debug" / "qs1000"
    raw = REPO / "debug" / f"{a.game}-qs1000raw"
    r = run(a.game, a.n, raw, a.frames, a.timeout)
    check_lua_error(raw)
    if not (raw / f"{a.game}_q.done").exists():
        sys.stdout.write(r.stdout[-2000:])
        sys.stderr.write(r.stderr[-2000:])
        sys.exit("no completion marker; see MAME output above")
    n, stats = convert(raw / f"{a.game}_q.raw", out, a.game, a.n)
    print(f"{n} instructions; accesses {sorted(stats.items())}")
    if not a.keep_raw:
        shutil.rmtree(raw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
