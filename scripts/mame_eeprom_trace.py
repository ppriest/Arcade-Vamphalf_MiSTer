#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Trace a set's 93C46 EEPROM traffic in MAME, across runs that keep MAME's saved EEPROM.

    python scripts/mame_eeprom_trace.py mrkickera --run 1 --fresh [--frames 3000] [--coin 600] [--fire 900]
    python scripts/mame_eeprom_trace.py mrkickera --run 2 [--snaps 300,600,900]

One MAME run (scripts/mame/iotrace.lua) with its own nvram/cfg/snapshot directories under --out, so
MAME's saved EEPROM carries from one run to the next (--fresh starts from the ROM's default). Writes
<out>/run<N>_io.txt (every I/O access: frame, PC, W|R, offset, data), decodes the EEPROM's serial
commands from the write port (--ee, the bit positions of DI, CS and CLK in the word written) and prints
them with their frame and PC, then the saved EEPROM.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths  # noqa: E402

# set: (write port offset as the tap reports it, DI bit, CS bit, CLK bit)
EE = {"mrkickera": (0x1000, 14, 12, 13), "finalgdr": (0x1800, 14, 12, 13), "yorijori": (0x1800, 12, 14, 13)}


def decode(log, port, di, cs, clk):
    """93C46 in x16 mode: start bit, 2-bit opcode, 6-bit address, 16 data bits for WRITE/WRAL."""
    cmds = []
    cs_l = clk_l = 0
    bits = []
    start = None
    for line in open(log, encoding="utf-8"):
        if line[0] == "#":
            continue
        fr, pc, rw, off, d = line.split()
        if rw != "W" or int(off, 16) != port:
            continue
        v = int(d, 16)
        c_cs, c_clk, c_di = (v >> cs) & 1, (v >> clk) & 1, (v >> di) & 1
        if c_cs and c_clk and not clk_l:
            if not bits and start is None:
                start = (int(fr), pc)
            bits.append(c_di)
        if cs_l and not c_cs and bits:
            cmds.append((start, bits))
            bits, start = [], None
        cs_l, clk_l = c_cs, c_clk
    out = []
    for (fr, pc), b in cmds:
        # leading zeros before the start bit are ignored by the part
        while b and b[0] == 0:
            b = b[1:]
        if len(b) < 9:
            out.append((fr, pc, "short %s" % "".join(map(str, b)), None, None))
            continue
        op = b[1] * 2 + b[2]
        addr = int("".join(map(str, b[3:9])), 2)
        data = int("".join(map(str, b[9:25])), 2) if len(b) >= 25 else None
        name = {2: "READ", 1: "WRITE", 3: "ERASE"}.get(op)
        if op == 0:
            name = {0: "EWDS", 1: "WRAL", 2: "ERAL", 3: "EWEN"}[addr >> 4]
        out.append((fr, pc, name, addr, data if name in ("WRITE", "WRAL") else None))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("--run", type=int, default=1)
    ap.add_argument("--fresh", action="store_true", help="start from the ROM's default EEPROM")
    ap.add_argument("--frames", type=int, default=3000)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--fire", type=int, default=0)
    ap.add_argument("--snaps", default="")
    ap.add_argument("--out", default=str(REPO / "debug" / "eeprom"))
    a = ap.parse_args()
    out = Path(a.out) / a.set
    out.mkdir(parents=True, exist_ok=True)
    nv = out / "nvram"
    if a.fresh and nv.exists():
        shutil.rmtree(nv)
    (out / "lua_error.txt").unlink(missing_ok=True)
    mame_dir, exe = mame_paths()
    log = out / f"run{a.run}_io.txt"
    snapdir = out / f"snap{a.run}"
    env = dict(os.environ, **lua_runner_env("iotrace.lua"), CORE_OUT=out.as_posix(),
               IT_OUT=log.resolve().as_posix(), IT_FRAMES=str(a.frames), IT_COIN=str(a.coin),
               IT_FIRE=str(a.fire), IT_SNAPS=a.snaps)
    extra = ["-nvram_directory", str(nv.resolve()), "-cfg_directory", str((out / "cfg").resolve()),
             "-snapshot_directory", str(snapdir.resolve())]
    r = subprocess.run(mame_cmd(exe, a.set, "iotrace.lua", mame_dir, extra), cwd=str(mame_dir), env=env,
                       capture_output=True, text=True, timeout=7200, **NO_WINDOW)
    check_lua_error(out)
    if not log.exists():
        sys.exit(f"no output; MAME said:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    if a.set in EE:
        for fr, pc, name, addr, data in decode(log, *EE[a.set]):
            print("frame %5d  pc %s  %-5s %s%s" % (fr, pc, name, "" if addr is None else "addr %02x" % addr,
                                                  "" if data is None else "  data %04x" % data))
    ee = nv / a.set / "eeprom"
    if ee.exists():
        b = ee.read_bytes()
        print("saved EEPROM (%s, %d bytes):" % (ee, len(b)))
        for i in range(0, len(b), 16):
            print("  %02x: %s" % (i, b[i:i + 16].hex(" ")))


if __name__ == "__main__":
    main()
