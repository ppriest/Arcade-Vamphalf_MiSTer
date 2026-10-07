#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Print records of an E1 instruction trace: the first one outside the program ROM, the first
repeated pc cycle, or a window around an index.

    python scripts/e1_trace_tail.py <instr.trace> [--at IDX] [--before 12] [--after 4]
"""
import argparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--at", type=int, default=None)
    ap.add_argument("--before", type=int, default=12)
    ap.add_argument("--after", type=int, default=4)
    a = ap.parse_args()
    rows = []
    for l in open(a.trace, encoding="utf-8", errors="replace"):
        if l[0] == "#":
            continue
        p = l.split(" | ")
        h = p[0].split(None, 4)
        rows.append((int(h[0]), int(h[1], 16), h[2], int(h[3], 16), p[1].strip()))
    at = a.at
    if at is None:
        for i, r in enumerate(rows):
            if r[1] < 0xfff80000:
                at = i
                print("first pc outside the ROM at", i)
                break
    if at is None:
        # first pc seen 50 times
        cnt = {}
        for i, r in enumerate(rows):
            cnt[r[1]] = cnt.get(r[1], 0) + 1
            if cnt[r[1]] == 50:
                at = i
                print("pc %08x seen 50 times at index %d" % (r[1], i))
                break
    if at is None:
        print("nothing unusual")
        return
    for r in rows[max(0, at - a.before): at + a.after]:
        print("%7d %08x %-14s sr=%08x %s" % r)


if __name__ == "__main__":
    main()
