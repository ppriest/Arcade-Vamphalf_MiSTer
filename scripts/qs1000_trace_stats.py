#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Summarise 8052-only resource use in a QS1000 trace (docs/QS1000_TRACE_FORMAT.md).

    python scripts/qs1000_trace_stats.py debug/qs1000/misncrft
"""
import sys
from collections import Counter, defaultdict

base = sys.argv[1]
dis = {}
first_pc = {}
n = 0
with open(base + "_instr.trace") as f:
    for line in f:
        if line[0] == "#":
            continue
        head, _, d = line.partition(" | ")
        t = head.split()
        dis[int(t[0])] = (int(t[1], 16), d.split(":", 1)[1].strip() if ":" in d else d.strip())
        n += 1
hi_by = defaultdict(Counter)       # kind of instruction -> count of idata >= 0x80 accesses
hi_pc = defaultdict(Counter)
hi_addr = Counter()
t2 = Counter()
sfr = Counter()
xs = Counter()
latch = []
for line in open(base + "_bus.trace"):
    if line[0] == "#":
        continue
    i, sp, k, a, d = line.split()
    i, a = int(i), int(a, 16)
    if sp == "L":
        latch.append((i, d))
        continue
    pc, text = dis.get(i, (0, "?"))
    m = text.split()[0] if text else "?"
    if sp == "I" and a >= 0x80:
        ind = "@r" in text
        kind = "indirect @Ri" if ind else ("push/pop/call/ret" if m in ("push", "pop", "lcall", "acall", "ret", "reti") else "other:" + m)
        hi_by[kind][k] += 1
        hi_pc[kind][pc] += 1
        hi_addr[a] += 1
    if sp == "S":
        sfr[(a, k)] += 1
        if 0xC8 <= a <= 0xCD:
            t2[(a, k)] += 1
    if sp == "X":
        xs[(a >> 8, k)] += 1
print(f"{n} instructions")
print("internal RAM >= 0x80 accesses by cause:", {k: dict(v) for k, v in hi_by.items()})
print("distinct addresses >= 0x80:", f"{min(hi_addr, default=0):02x}-{max(hi_addr, default=0):02x}", len(hi_addr))
for k, v in hi_pc.items():
    print(f"  {k}: {len(v)} distinct PCs, e.g. {[f'{p:04x}' for p in sorted(v)[:8]]}")
print("Timer 2 SFR (C8-CD) accesses:", sum(t2.values()), dict(t2))
print("SFR accesses:", {f"{a:02x}{k}": c for (a, k), c in sorted(sfr.items())})
print("external data accesses by page:", {f"{a:02x}{k}": c for (a, k), c in sorted(xs.items())})
print("latch writes (idx, data):", latch)
