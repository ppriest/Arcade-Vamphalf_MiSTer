#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Convert the raw log of scripts/mame/e1trace.lua to the E1 trace files.

    python scripts/e1trace_convert.py <raw> <outdir> <set> <n> [bus_bytes: 2|4]

Format: docs/E1_TRACE_FORMAT.md. Reads the raw file once, streaming.
"""
import sys
from pathlib import Path

GNAMES = ["g%d" % i for i in range(32)]
NREG = 32 + 64
REGNAMES = GNAMES + ["l%d" % i for i in range(64)]   # l<i>: absolute local array, MAME's S<i>


def convert(raw, outdir, game, n, bus_bytes=2):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    fi = open(outdir / f"{game}_instr.trace", "w", encoding="utf-8", newline="\n")
    fb = open(outdir / f"{game}_bus.trace", "w", encoding="utf-8", newline="\n")
    fi.write("# E1 instruction trace, MAME interpreter (-nodrc), state BEFORE each instruction.\n")
    fi.write("# format: docs/E1_TRACE_FORMAT.md\n")
    fi.write("# idx pc ops sr changes | disasm\n")
    fb.write("# E1 bus trace; idx = index of the instruction executing. Format: docs/E1_TRACE_FORMAT.md\n")
    fb.write("# idx kind space addr data mask\n")

    wide = bus_bytes == 4
    dfmt = "%08x" if wide else "%04x"

    def half_mask(addr):
        """Lane mask of an instruction-halfword read at byte address addr."""
        if not wide:
            return 0xFFFF
        return 0x0000FFFF if addr & 2 else 0xFFFF0000

    def norm(sp, a, d, m):
        """32-bit bus, program space: the tap's offset is the dword address and the lane
        is in the mask; return the byte address of the first lane and the data of the lanes driven."""
        if sp == "P":
            for lane in range(4):
                if m & (0xFF000000 >> (8 * lane)):
                    a += lane
                    break
        return a, d & m, m

    idx = -1
    prev = None
    pending = []          # bus rows of the current instruction
    cur = None            # (idx, pc, opwords)
    stats = {"pre_run_bus": 0, "bad_pc": 0, "instr": 0, "bus": 0}
    frame_marks = []
    pre = True

    def flush_instr():
        nonlocal cur, pending
        if cur is None:
            return
        i, pc, ops3, sr, chg, dis = cur
        # fetch words: consecutive full-width reads from pc
        words = 0
        rows = []
        for sp, kind, addr, data, mask in pending:
            tag = kind
            if (sp == "P" and kind == "R" and mask == half_mask(addr) and words < 3
                    and addr == pc + 2 * words):
                tag = "F"
                words += 1
            rows.append((tag, sp, addr, data, mask))
        words = max(words, 1)
        ops = ",".join("%04x" % w for w in ops3[:words])
        fi.write("%d %08x %s %08x %s | %s\n" % (i, pc, ops, sr, chg, dis))
        for tag, sp, addr, data, mask in rows:
            fb.write("%d %s %s %08x %s %s" % (i, tag, sp, addr, dfmt % data, dfmt % mask) + chr(10))
            stats["bus"] += 1
        stats["instr"] += 1
        cur = None
        pending = []

    with open(raw, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("I "):
                flush_instr()
                idx += 1
                if idx >= n:
                    break
                pre = False
                head, _, dis = line.rstrip("\n").partition(" ")[2].partition(" ")[2], None, None
                parts = line.rstrip("\n").split(" ")
                ops3 = [int(parts[1], 16), int(parts[2], 16), int(parts[3], 16)]
                regs = [int(x, 16) for x in parts[4:4 + NREG]]
                dis = " ".join(parts[4 + NREG:])
                pc = regs[0]
                if not dis.upper().startswith("%08X:" % pc):
                    stats["bad_pc"] += 1
                if prev is None:
                    chg = " ".join("%s=%08x" % (REGNAMES[k], regs[k])
                                   for k in range(2, NREG))
                else:
                    chg = " ".join("%s=%08x" % (REGNAMES[k], regs[k])
                                   for k in range(2, NREG) if regs[k] != prev[k])
                prev = regs
                cur = (idx, pc, ops3, regs[1], chg, dis)
            elif line.startswith("B "):
                _, sp, kind, a, d, m = line.split()
                spc = "P" if sp == "0" else "I"
                av, dv, mv = int(a, 16), int(d, 16), int(m, 16)
                if wide:
                    av, dv, mv = norm(spc, av, dv, mv)
                else:
                    dv, mv = dv & 0xFFFF, mv & 0xFFFF
                row = (spc, "R" if kind == "0" else "W", av, dv, mv)
                if pre:
                    stats["pre_run_bus"] += 1
                else:
                    pending.append(row)
            elif line.startswith("# frame"):
                fi.write("# frame %s starts before idx %d\n" % (line.split()[2], idx + 1))
    flush_instr()
    fi.write("# %d instructions\n" % stats["instr"])
    fb.write("# %d bus accesses\n" % stats["bus"])
    fi.close()
    fb.close()
    print("instr %d bus %d (pre-run reads dropped: %d, disasm/PC mismatches: %d)"
          % (stats["instr"], stats["bus"], stats["pre_run_bus"], stats["bad_pc"]))
    return stats


if __name__ == "__main__":
    convert(sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]),
            int(sys.argv[5]) if len(sys.argv) > 5 else 2)
