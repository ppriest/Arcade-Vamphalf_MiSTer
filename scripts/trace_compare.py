#!/usr/bin/env python3
"""Compare the board's architectural trace with the bench's (rtl/debug/vh_trace.sv).

    python scripts/read_trace.py 0 > board.txt
    scripts/run_verilator.sh sys_tb ... +trace=bench.txt +trstart=0
    python scripts/trace_compare.py bench.txt board.txt

Board and bench timing differ (SDRAM refresh phase, the download), so the interleaving of bus
transfers can differ while every value agrees. The streams are compared by category, each in its own
order: instructions retired (PC and SR after each), register-file writes (slot, value), data transfers
(address, direction, byte enables, value), and instruction fetches (each address's data, against the
bench's data for the same address). For each category the first difference is printed with the
instruction count it falls in, so the first wrong value can be named.
"""
import sys


def parse(path):
    recs = []
    for ln in open(path, encoding="utf-8", errors="replace"):
        if not ln.startswith("TR "):
            continue
        v = int(ln[3:].strip(), 16)
        f = {
            "cyc": (v >> 176) & 0xfff,
            "ret": (v >> 175) & 1, "rf": (v >> 174) & 1, "bus": (v >> 173) & 1,
            "wr": (v >> 172) & 1, "io": (v >> 171) & 1, "if": (v >> 170) & 1,
            "be": (v >> 166) & 0xf, "wa": (v >> 160) & 0x3f,
            "npc": (v >> 128) & 0xffffffff, "sr": (v >> 96) & 0xffffffff,
            "wd": (v >> 64) & 0xffffffff, "addr": (v >> 32) & 0xffffffff, "data": v & 0xffffffff,
        }
        recs.append(f)
    return recs


def streams(recs):
    ret, rf, data, fetch = [], [], [], []
    n = 0
    for r in recs:
        if r["rf"]:
            rf.append((n, r["wa"], r["wd"]))
        if r["bus"]:
            if r["if"]:
                fetch.append((n, r["addr"], r["data"]))
            else:
                data.append((n, r["wr"], r["io"], r["be"], r["addr"], r["data"]))
        if r["ret"]:
            ret.append((n, r["npc"], r["sr"]))
            n += 1
    return ret, rf, data, fetch


def first_diff(a, b, key):
    for i in range(min(len(a), len(b))):
        if key(a[i]) != key(b[i]):
            return i
    return None


def main():
    a, b = parse(sys.argv[1]), parse(sys.argv[2])
    print(f"bench {len(a)} records, board {len(b)} records")
    sa, sb = streams(a), streams(b)
    names = ["retire (npc, sr)", "register writes (slot, value)", "data transfers (wr, io, be, addr, value)"]
    keys = [lambda t: t[1:], lambda t: t[1:], lambda t: t[1:]]
    worst = None
    for name, x, y, k in zip(names, sa[:3], sb[:3], keys):
        i = first_diff(x, y, k)
        n = min(len(x), len(y))
        if i is None:
            print(f"{name}: {n} compared, identical")
            continue
        print(f"{name}: first difference at entry {i} (instruction {x[i][0]} bench, {y[i][0]} board)")
        for j in range(max(0, i - 3), min(n, i + 4)):
            mark = ">>" if j == i else "  "
            print(f"  {mark} bench {tuple(hex(v) for v in x[j][1:])}   board {tuple(hex(v) for v in y[j][1:])}")
        if worst is None or x[i][0] < worst[0]:
            worst = (x[i][0], name)
    bench_fetch = {}
    for _, ad, d in sa[3]:
        bench_fetch.setdefault(ad, d)
    bad = [(n, ad, d, bench_fetch[ad]) for n, ad, d in sb[3] if ad in bench_fetch and bench_fetch[ad] != d]
    print(f"instruction fetches: {len(sb[3])} on the board, {len(bad)} with data unlike the bench's for that address")
    for n, ad, d, e in bad[:8]:
        print(f"   instruction {n}: fetch {ad:08x} board {d:08x} bench {e:08x}")
        if worst is None or n < worst[0]:
            worst = (n, "fetch data")
    if worst:
        print(f"earliest difference: instruction {worst[0]}, {worst[1]}")
    else:
        print("no difference in the compared range")


if __name__ == "__main__":
    main()
