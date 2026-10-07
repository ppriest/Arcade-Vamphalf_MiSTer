#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Primary-opcode coverage of one or more E1 instruction traces.

    python scripts/e1_coverage.py <instr.trace>... [--missing]

An opcode counts when an instruction with that high byte was executed (traps and interrupts
included: the handler's RET is its own instruction). 0xcf (DO) is fatal in MAME and not counted
as missing.
"""
import sys


def opcodes(path, n=None):
    seen = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line[0] == "#":
                continue
            p = line.split(None, 4)
            op = int(p[2].split(",")[0], 16) >> 8
            seen[op] = seen.get(op, 0) + 1
    return seen


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    tot = {}
    for p in args:
        for k, v in opcodes(p).items():
            tot[k] = tot.get(k, 0) + v
    miss = [o for o in range(256) if o not in tot and o != 0xcf]
    print("%d of 255 primary opcodes executed (0xcf excluded); missing: %s" %
          (255 - len(miss), " ".join("%02x" % o for o in miss) or "none"))


if __name__ == "__main__":
    main()
