#!/usr/bin/env python3
"""Cache model for the E1's path to SDRAM, driven by a MAME bus trace (docs/E1_TRACE_FORMAT.md).

    python scripts/cpu_mem_model.py <set>_bus.trace <set>_instr.trace [--skip-frames N]

Reports, over the frames after --skip-frames: instructions per frame, accesses by region and kind,
and for each cache configuration the misses per 1000 instructions. Instruction fetches and data reads
of work RAM (0x00000000-0x001fffff) and program ROM (0xfff00000-) go through the model; sprite RAM,
palette and I/O are BRAM or registers and are counted only. Writes are write-through: counted per
1000 instructions and, with --wbuf, the stalls a write buffer of that depth would leave at a given
SDRAM write cost.
"""
import argparse
import collections
import re


def region(a):
    if a < 0x00200000:
        return "wram"
    if 0x40000000 <= a < 0x40040000:
        return "spr"
    if 0x80000000 <= a < 0x80010000:
        return "pal"
    if a >= 0xfff00000:
        return "rom"
    return "other"


class Cache:
    """Direct-mapped or 2-way LRU, line `line` bytes, `size` bytes total."""

    def __init__(self, size, line, ways=1):
        self.line, self.ways = line, ways
        self.sets = size // (line * ways)
        self.tags = [[None] * ways for _ in range(self.sets)]
        self.misses = 0
        self.acc = 0

    def access(self, a, fill=True):
        self.acc += 1
        ln = a // self.line
        s = self.tags[ln % self.sets]
        if ln in s:
            if self.ways > 1 and s[0] != ln:
                s.remove(ln)
                s.insert(0, ln)
            return True
        self.misses += 1
        if fill:
            s.pop()
            s.insert(0, ln)
        return False

    def update(self, a):   # write: update in place if present (write-through, no allocate)
        pass


def frame_starts(instr_path):
    starts = []
    pat = re.compile(r"# frame (\d+) starts before idx (\d+)")
    with open(instr_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("# frame"):
                m = pat.match(line)
                if m:
                    starts.append(int(m.group(2)))
    return starts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bus")
    ap.add_argument("instr")
    ap.add_argument("--skip-frames", type=int, default=10)
    a = ap.parse_args()

    starts = frame_starts(a.instr)
    first = starts[a.skip_frames] if len(starts) > a.skip_frames else 0
    last = starts[-1]
    nframes = len(starts) - 1 - a.skip_frames

    icfg = [(16384, 16, 1), (16384, 32, 1)]
    dcfg = [(s, l, 1) for s in (4096, 8192) for l in (16, 32, 64)]
    ic = {c: Cache(*c) for c in icfg}
    dc = {c: Cache(*c) for c in dcfg}
    counts = collections.Counter()
    # write bursts: distance in instructions between consecutive SDRAM writes
    wgap = collections.Counter()
    last_w = None

    with open(a.bus, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line[0] == "#":
                continue
            p = line.split()
            idx = int(p[0])
            if idx < first:
                continue
            if idx >= last:
                break
            kind, space, addr = p[1], p[2], int(p[3], 16)
            if space == "I":
                counts[("io", kind)] += 1
                continue
            r = region(addr)
            counts[(r, kind)] += 1
            if r not in ("wram", "rom"):
                continue
            if kind == "F":
                for c in ic.values():
                    c.access(addr)
            elif kind == "R":
                for c in dc.values():
                    c.access(addr)
            else:
                g = idx - last_w if last_w is not None else 999
                wgap[min(g, 8)] += 1
                last_w = idx

    ninstr = last - first
    k = 1000.0 / ninstr
    print(f"frames {a.skip_frames}..{len(starts) - 2}: {nframes} frames, {ninstr} instructions, "
          f"{ninstr / nframes:.0f} per frame")
    print("accesses per 1000 instructions:")
    for key in sorted(counts):
        print(f"  {key[0]:6s} {key[1]}  {counts[key] * k:8.1f}")
    print("I-cache (fetch rows of wram+rom): misses per 1000 instructions")
    for c, m in ic.items():
        print(f"  {c[0]:6d} B line {c[1]:2d} {c[2]}-way  {m.misses * k:7.2f}")
    print("D-cache (read rows of wram+rom, no write allocate): misses per 1000 instructions")
    for c, m in dc.items():
        print(f"  {c[0]:6d} B line {c[1]:2d} {c[2]}-way  {m.misses * k:7.2f}")
    print("SDRAM writes: gap in instructions to the previous write (8 = 8 or more)")
    tot = sum(wgap.values()) or 1
    for g in sorted(wgap):
        print(f"  {g}: {100.0 * wgap[g] / tot:5.1f}%")


if __name__ == "__main__":
    main()
